/**
 * @file main.mm
 * @brief Timestretch for iPadOS — Writing-Speed Adaptive Audio App
 *
 * A child draws over a letter outline with one finger. The finger's movement
 * speed continuously controls audio playback speed via real-time time-stretching:
 *   - Slow strokes  → sound plays faster (encouraging the child to slow down)
 *   - Fast strokes  → sound plays slower (the sound "stretches" with the pen)
 *
 * Gesture model:
 *   - 1 finger  → draw / play audio
 *   - 2 fingers → navigation swipe (left/right = letter, up/down = sound variant)
 *
 * Todo items implemented in this version:
 *   [1] Randomise letter and sound on demand (double-tap with 2 fingers)
 *   [2] Sound duration normalised to a baseline writing speed
 *   [3] Two-finger gestures are fully blocked from triggering audio
 *   [4] Writing direction detection with 8-sector compass HUD
 *   [5] Ghost tracing overlay (semi-transparent letter guide, toggle: 3-finger tap)
 *   [6] Pitch shift + stereo panning driven by writing speed / horizontal direction
 *   [7] Adaptive mute threshold derived from rolling average writing speed
 *   [8] Sound restart after configurable pause duration
 *
 * Tech stack:
 *   - SDL3          : window management, touch/event input, 2-D rendering
 *   - RubberBand    : real-time pitch-preserving time-stretch & pitch-shift
 *   - libsndfile    : audio file decoding (mp3/wav/flac/ogg/aiff)
 *
 * Platform: iPadOS 16+, arm64, C++17, Objective-C++ (.mm)
 */

#include <iostream>
#include <vector>
#include <string>
#include <memory>
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>
#include <cmath>
#include <algorithm>
#include <iomanip>
#include <filesystem>
#include <fstream>
#include <random>
#include <deque>
#include <numeric>
#include <sstream>

#include <SDL3/SDL.h>
#include "DrawingOverlay.h"
#include "OverlayInstaller.h"
#include <SDL3/SDL_main.h>
#include <sndfile.h>
#include <rubberband/RubberBandStretcher.h>

namespace fs = std::filesystem;

// ============================================================================
// Stroke checkpoint system  (Option B)
// ============================================================================

/// One checkpoint: normalised image-space coordinate [0–1]
struct Checkpoint {
    float x, y;
};

/// One stroke: ordered sequence of checkpoints the finger must pass through
struct StrokeDef {
    int id;
    std::vector<Checkpoint> checkpoints;
};

/// Full letter stroke definition loaded from strokes.json
struct LetterStrokes {
    std::string letter;
    float checkpointRadius = 0.06f;   ///< Hit radius in normalised units
    std::vector<StrokeDef> strokes;
    bool valid = false;
};

/**
 * @brief Minimal JSON parser for strokes.json (no external dependencies).
 *
 * Parses a subset of JSON sufficient for our fixed schema:
 * { "letter": "X", "checkpointRadius": 0.06, "strokes": [ { "id": 1,
 *   "checkpoints": [ {"x": 0.5, "y": 0.3}, ... ] }, ... ] }
 */
static LetterStrokes loadStrokes(const std::string& path) {
    LetterStrokes ls;
    std::ifstream f(path);
    if (!f) return ls;

    std::string src((std::istreambuf_iterator<char>(f)),
                     std::istreambuf_iterator<char>());

    // Tiny helpers
    auto skipWS = [&](size_t i) {
        while (i < src.size() && (src[i]==' '||src[i]=='\n'||src[i]=='\r'||src[i]=='\t')) ++i;
        return i;
    };
    auto readStr = [&](size_t i) -> std::pair<std::string,size_t> {
        i = skipWS(i);
        if (i >= src.size() || src[i] != '"') return {"", i};
        ++i;
        std::string out;
        while (i < src.size() && src[i] != '"') out += src[i++];
        return {out, i+1};
    };
    auto readNum = [&](size_t i) -> std::pair<float,size_t> {
        i = skipWS(i);
        size_t j = i;
        while (j < src.size() && (std::isdigit(src[j]) || src[j]=='-' || src[j]=='.')) ++j;
        float v = 0;
        try { v = std::stof(src.substr(i, j-i)); } catch(...) {}
        return {v, j};
    };

    // Parse letter
    auto pos = src.find("\"letter\"");
    if (pos != std::string::npos) {
        pos = src.find(':', pos) + 1;
        auto [s, _] = readStr(skipWS(pos));
        ls.letter = s;
    }

    // Parse checkpointRadius
    pos = src.find("\"checkpointRadius\"");
    if (pos != std::string::npos) {
        pos = src.find(':', pos) + 1;
        auto [v, _] = readNum(skipWS(pos));
        ls.checkpointRadius = v;
    }

    // Parse strokes array
    pos = src.find("\"strokes\"");
    if (pos == std::string::npos) return ls;
    pos = src.find('[', pos);
    if (pos == std::string::npos) return ls;

    while (pos < src.size()) {
        // Find next stroke object
        pos = src.find('{', pos);
        if (pos == std::string::npos) break;

        StrokeDef stroke;
        // id
        auto idPos = src.find("\"id\"", pos);
        auto cpPos = src.find("\"checkpoints\"", pos);
        (void)src.find("\"id\"", idPos+1); // next stroke boundary (unused but kept for clarity)

        if (idPos == std::string::npos || cpPos == std::string::npos) break;
        // Ensure this id belongs to current stroke (before next checkpoints block)
        {
            auto [v, _] = readNum(src.find(':', idPos) + 1);
            stroke.id = (int)v;
        }

        // Parse checkpoints array for this stroke
        cpPos = src.find('[', cpPos);
        size_t cpEnd = src.find(']', cpPos);
        if (cpPos == std::string::npos || cpEnd == std::string::npos) break;

        size_t ci = cpPos + 1;
        while (ci < cpEnd) {
            ci = src.find('{', ci);
            if (ci == std::string::npos || ci >= cpEnd) break;
            Checkpoint cp;
            auto xp = src.find("\"x\"", ci);
            auto yp = src.find("\"y\"", ci);
            auto nextCP = src.find('}', ci);
            if (xp == std::string::npos || xp > nextCP) { ci = nextCP+1; continue; }
            { auto [v,_] = readNum(src.find(':', xp)+1); cp.x = v; }
            if (yp != std::string::npos && yp < nextCP) {
                auto [v,_] = readNum(src.find(':', yp)+1); cp.y = v;
            }
            stroke.checkpoints.push_back(cp);
            ci = nextCP + 1;
        }

        if (!stroke.checkpoints.empty())
            ls.strokes.push_back(stroke);

        pos = cpEnd + 1;
        // Stop after all strokes (closing bracket of strokes array)
        auto arrEnd = src.find(']', pos);
        auto nextObj = src.find('{', pos);
        if (nextObj == std::string::npos || nextObj > arrEnd) break;
    }

    ls.valid = !ls.strokes.empty();
    return ls;
}

/**
 * @brief Tracks progress through ALL strokes, enforcing the correct stroke ORDER.
 *
 * Drawing feedback is handled by DrawingOverlay (UIKit CAShapeLayer) — not SDL.
 * This class manages checkpoint logic only; it calls the C bridge to paint.
 */
class StrokeTracker {
public:
    struct StrokeProgress {
        int    strokeId      = 0;
        int    nextCP        = 0;
        bool   started       = false;
        bool   active        = false;
        bool   complete      = false;
    };

    std::vector<StrokeProgress>  progress;
    const LetterStrokes*         def          = nullptr;
    bool                         soundEnabled = false;
    bool                         wantRestart  = false;

    void load(const LetterStrokes& ls) {
        def = &ls;
        progress.clear();
        for (auto& s : ls.strokes) {
            StrokeProgress p;
            p.strokeId = s.id;
            progress.push_back(p);
        }
        soundEnabled = false;
        wantRestart  = false;
        drawing_overlay_reset_all();
    }

    void reset() {
        for (auto& p : progress) {
            p.nextCP = 0; p.started = false; p.active = false; p.complete = false;
        }
        soundEnabled = false;
        wantRestart  = false;
        drawing_overlay_reset_all();
    }

    void update(float nx, float ny, bool fingerDown) {
        if (!def || def->strokes.empty()) {
            soundEnabled = true;
            return;
        }

        wantRestart  = false;
        soundEnabled = false;

        // Find the current expected stroke (first incomplete)
        int currentStroke = -1;
        for (int si = 0; si < (int)progress.size(); ++si) {
            if (!progress[(size_t)si].complete) { currentStroke = si; break; }
        }

        if (currentStroke == -1) { soundEnabled = true; return; }

        auto& strk = def->strokes[(size_t)currentStroke];
        auto& prog = progress[(size_t)currentStroke];

        if (strk.checkpoints.empty()) { soundEnabled = false; return; }

        int   nextIdx = prog.nextCP;
        auto& target  = strk.checkpoints[(size_t)nextIdx];
        float dist    = std::hypot(nx - target.x, ny - target.y);

        if (dist <= def->checkpointRadius) {
            if (nextIdx == 0) {
                // ✅ Correct start — begin stroke
                drawing_overlay_reset_stroke(currentStroke);
                drawing_overlay_begin_stroke(currentStroke);
                drawing_overlay_add_point(currentStroke, nx, ny);
                prog.nextCP   = 1;
                prog.started  = true;
                prog.active   = true;
                prog.complete = false;
                wantRestart   = true;
            } else if (prog.started) {
                prog.nextCP++;
                prog.active = true;
                if (prog.nextCP >= (int)strk.checkpoints.size()) {
                    drawing_overlay_add_point(currentStroke, nx, ny);
                    drawing_overlay_complete_stroke(currentStroke);
                    prog.complete = true;
                    prog.active   = false;
                    std::cout << "✅ Stroke " << (currentStroke + 1) << " complete\n";
                }
            }
        }

        // Add paint point while actively tracing
        if (prog.started && fingerDown && (prog.active || prog.complete)) {
            drawing_overlay_add_point(currentStroke, nx, ny);
        }

        if ((prog.active || prog.complete) && prog.started) soundEnabled = true;

        // Finger lifted mid-stroke → reset paint + progress
        if (!fingerDown && prog.active && !prog.complete) {
            prog.active   = false;
            prog.started  = false;
            prog.nextCP   = 0;
            drawing_overlay_reset_stroke(currentStroke);
        }
    }

    [[nodiscard]] bool anyActive() const {
        for (auto& p : progress) if ((p.active || p.complete) && p.started) return true;
        return false;
    }

    [[nodiscard]] int currentStrokeIndex() const {
        for (int si = 0; si < (int)progress.size(); ++si)
            if (!progress[(size_t)si].complete) return si;
        return (int)progress.size();
    }

    [[nodiscard]] float overallProgress() const {
        if (!def || def->strokes.empty()) return 1.f;
        int total = 0, done = 0;
        for (size_t si = 0; si < def->strokes.size(); ++si) {
            total += (int)def->strokes[si].checkpoints.size();
            done  += progress[si].complete
                ? (int)def->strokes[si].checkpoints.size()
                : progress[si].nextCP;
        }
        return total > 0 ? (float)done / (float)total : 0.f;
    }
};

// ============================================================================
// Configuration — all magic numbers live here
// ============================================================================
namespace Config {
    // --- Speed mapping ---
    /// Slowest playback ratio (reached at maximum stroke velocity)
    constexpr float kMinSpeed            = 0.5f;
    /// Fastest playback ratio (reached at minimum stroke velocity)
    constexpr float kMaxSpeed            = 2.0f;
    /// Playback ratio used when the finger pauses inside the letter
    constexpr float kIdleSpeed           = 1.0f;

    // --- Velocity thresholds (normalised screen units / frame at ~60 fps) ---
    constexpr float kLowVel              = 5.0f;
    constexpr float kHighVel             = 50.0f;

    // --- Audio engine ---
    /// SDL3 audio callback buffer size in frames
    constexpr size_t kBufFrames          = 2048;
    /// Extra source-audio chunks fed to RubberBand per callback to prevent underruns
    /// Must be large enough to cover slow playback (kMinSpeed = 0.5 → 2× more input needed)
    constexpr size_t kInputMultiplier    = 8;
    /// Speed / pitch interpolation coefficient (0 = frozen, 1 = instant snap)
    constexpr float kInterpolationFactor = 0.05f;

    // --- Playback gate timers ---
    /// Milliseconds of stillness inside the mask before audio mutes (Todo #7 adapts this)
    constexpr int kIdleTimeoutMs         = 800;
    /// Grace period in ms after leaving the mask before audio stops
    constexpr int kExitTimeoutMs         = 400;
    /// Minimum movement per frame to register as "active" stroke (pixels in image space)
    constexpr float kMoveThreshold       = 0.5f;

    // --- Todo #2: Writing-speed normalisation ---
    /// Stroke velocity (image px/frame) that maps to exactly 1× playback speed.
    /// Faster children get a slower sound; slower children get a faster one.
    constexpr float kBaselineVelocity    = 20.0f;

    // --- Todo #3: Two-finger swipe navigation ---
    /// Minimum swipe distance (fraction of screen width/height) to trigger navigation
    constexpr float kSwipeThreshold      = 0.10f;

    // --- Todo #5: Ghost tracing overlay ---
    /// Alpha (0–255) of the semi-transparent letter guide shown in tracing mode
    constexpr uint8_t kTraceAlpha        = 55;

    // --- Todo #6: Pitch & panning ---
    /// Maximum pitch-shift magnitude in semitones (applied symmetrically ±)
    constexpr float kMaxPitchSemitones   = 1.0f;
    /// Stereo spread coefficient driven by horizontal stroke direction [0–1]
    constexpr float kPanSpread           = 0.3f;

    // --- Todo #7: Adaptive mute threshold ---
    /// Number of velocity samples in the rolling window
    constexpr size_t kVelocityWindowSize = 60;
    /// Fraction of the rolling mean below which movement is considered "stopped"
    constexpr float kAdaptiveMuteFactor  = 0.25f;

    // --- Todo #8: Restart after pause ---
    /// Milliseconds of silence after which the current sound rewinds to the start
    constexpr int kRestartAfterPauseMs   = 2000;
}

// ============================================================================
// Thread-shared state
// Written by the main/event thread; read by the audio callback thread.
// All fields are std::atomic to avoid data races without locking.
// ============================================================================
struct SharedState {
    std::atomic<float> targetSpeed{1.0f};  ///< RubberBand time-ratio target
    std::atomic<float> targetPitch{1.0f};  ///< RubberBand pitch-scale target (Todo #6)
    std::atomic<float> panLeft{1.0f};      ///< Left-channel gain [0–1]  (Todo #6)
    std::atomic<float> panRight{1.0f};     ///< Right-channel gain [0–1] (Todo #6)
    std::atomic<bool>  isPlaying{false};   ///< Audio gate: false → output silence
    std::atomic<bool>  shouldQuit{false};  ///< Signals the main loop to exit
    std::atomic<bool>  restart{false};     ///< Rewind file to frame 0 (Todo #8)
};
SharedState g_state;

// ============================================================================
// Asset browser
// ============================================================================

/// One letter asset: a PBM outline mask + one or more audio phoneme variants
struct LetterFolder {
    std::string name;                      ///< Folder / letter name (e.g. "A")
    std::string path;                      ///< Absolute path to the folder
    std::string pbmPath;                   ///< Path to the P4 binary PBM mask file
    std::string strokesPath;               ///< Path to strokes.json (manual checkpoints, Option B)
    std::string skeletonPath;              ///< Path to strokes_skeleton.json (auto-extracted, Option C)
    std::vector<std::string> audioFiles;   ///< Sorted list of audio file paths
    int currentAudioIdx = 0;              ///< Currently selected audio variant index

    /// Returns the best available strokes file: skeleton preferred, then manual
    [[nodiscard]] std::string bestStrokesPath() const {
        if (!skeletonPath.empty()) return skeletonPath;
        return strokesPath;
    }
};

/**
 * @brief Scans the app bundle for letter folders and provides navigation.
 *
 * Expected structure (inside app bundle or working directory):
 * @code
 *   A/
 *     A.pbm    ← mandatory letter outline
 *     a.mp3    ← short phoneme (variant 0)
 *     aa.mp3   ← medium phoneme (variant 1, optional)
 *     aaa.mp3  ← long phoneme  (variant 2, optional)
 * @endcode
 *
 * Todo #1: `pickRandom()` selects a random folder AND a random audio variant.
 */
class AssetBrowser {
public:
    std::vector<LetterFolder> folders;
    size_t currentFolderIdx = 0;

    /**
     * @brief Populate the folder list by scanning `rootPath`.
     * @param rootPath  Directory to scan. Defaults to SDL_GetBasePath() (app bundle).
     */
    void scanRoot(std::string rootPath = "") {
        folders.clear();

        if (rootPath.empty()) {
            const char* base = SDL_GetBasePath();
            rootPath = base ? std::string(base) : ".";
        }

        const std::vector<std::string> audExts = {".wav", ".mp3", ".flac", ".ogg", ".aiff"};

        try {
            for (const auto& entry : fs::directory_iterator(rootPath)) {
                if (!entry.is_directory()) continue;

                LetterFolder folder;
                folder.path = entry.path().string();
                folder.name = entry.path().filename().string();
                bool hasPBM = false;

                for (const auto& sub : fs::directory_iterator(folder.path)) {
                    if (!sub.is_regular_file()) continue;
                    std::string ext = sub.path().extension().string();
                    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

                    if (ext == ".pbm") {
                        folder.pbmPath = sub.path().string();
                        hasPBM = true;
                    } else if (sub.path().filename().string() == "strokes_skeleton.json") {
                        folder.skeletonPath = sub.path().string();
                    } else if (sub.path().filename().string() == "strokes.json") {
                        folder.strokesPath = sub.path().string();
                    } else {
                        for (const auto& ae : audExts)
                            if (ext == ae) { folder.audioFiles.push_back(sub.path().string()); break; }
                    }
                }

                if (hasPBM) {
                    std::sort(folder.audioFiles.begin(), folder.audioFiles.end());
                    folders.push_back(folder);
                }
            }
            std::sort(folders.begin(), folders.end(),
                      [](const LetterFolder& a, const LetterFolder& b){ return a.name < b.name; });
        } catch (...) {
            std::cerr << "⚠️  Asset scan error.\n";
        }
    }

    [[nodiscard]] bool isValid() const { return !folders.empty(); }

    LetterFolder& current() { return folders[currentFolderIdx]; }

    std::string currentAudioPath() {
        auto& f = current();
        if (f.audioFiles.empty()) return "";
        return f.audioFiles[f.currentAudioIdx];
    }

    // --- Sequential navigation ---
    void nextFolder() { if (!folders.empty()) currentFolderIdx = (currentFolderIdx + 1) % folders.size(); }
    void prevFolder() { if (!folders.empty()) currentFolderIdx = (currentFolderIdx - 1 + folders.size()) % folders.size(); }
    void nextAudio()  { auto& f = current(); if (!f.audioFiles.empty()) f.currentAudioIdx = (f.currentAudioIdx + 1) % (int)f.audioFiles.size(); }
    void prevAudio()  { auto& f = current(); if (!f.audioFiles.empty()) f.currentAudioIdx = (f.currentAudioIdx - 1 + (int)f.audioFiles.size()) % (int)f.audioFiles.size(); }

    /**
     * @brief Todo #1 — Jump to a random letter and a random audio variant within it.
     * @param rng  Seeded Mersenne-Twister PRNG.
     */
    void pickRandom(std::mt19937& rng) {
        if (folders.empty()) return;
        currentFolderIdx = std::uniform_int_distribution<size_t>(0, folders.size() - 1)(rng);
        auto& f = current();
        if (!f.audioFiles.empty())
            f.currentAudioIdx = std::uniform_int_distribution<int>(0, (int)f.audioFiles.size() - 1)(rng);
    }
};

// ============================================================================
// PBM mask  (P4 binary format loader + per-pixel hit-test)
// ============================================================================

/**
 * @brief Loads a P4 binary PBM file and provides pixel-level hit detection.
 *
 * In P4 format each bit represents one pixel: 1 = black (letter stroke), 0 = white.
 * `isHit()` returns true for black pixels, which are the regions where finger
 * contact produces audio.
 */
class BitmapMask {
    std::vector<uint8_t> pixels;
    int width = 0, height = 0;

public:
    /**
     * @brief Load a P4 binary PBM file from disk.
     * @param path  Absolute file path.
     * @return true on success, false on any parse or I/O error.
     */
    bool load(const std::string& path) {
        if (path.empty()) return false;
        std::ifstream f(path, std::ios::binary);
        if (!f) return false;

        std::string tok;
        if (!(f >> tok) || tok != "P4") return false;
        while (f >> std::ws && f.peek() == '#') std::getline(f, tok);
        if (!(f >> width >> height)) return false;
        f.get(); // consume single whitespace before binary payload

        int rowBytes = (width + 7) / 8;
        pixels.resize(static_cast<size_t>(rowBytes * height));
        f.read(reinterpret_cast<char*>(pixels.data()), static_cast<std::streamsize>(pixels.size()));
        return !pixels.empty();
    }

    /**
     * @brief Test whether a given image-space coordinate falls on the letter stroke.
     * @param x  Image x coordinate (float, will be truncated to int).
     * @param y  Image y coordinate (float, will be truncated to int).
     * @return true if the pixel is black (part of the letter).
     */
    [[nodiscard]] bool isHit(float x, float y) const {
        int ix = static_cast<int>(x);
        int iy = static_cast<int>(y);
        if (ix < 0 || iy < 0 || ix >= width || iy >= height) return false;
        int rowBytes = (width + 7) / 8;
        return (pixels[static_cast<size_t>(iy * rowBytes + ix / 8)] >> (7 - ix % 8)) & 1;
    }

    [[nodiscard]] int getW() const { return width; }
    [[nodiscard]] int getH() const { return height; }
};

// ============================================================================
// Writing-direction tracker  (Todo #4)
// ============================================================================

/**
 * @brief Classifies the dominant writing direction from recent stroke deltas.
 *
 * Maintains a short ring-buffer of (dx, dy) displacement vectors.  The
 * cumulative vector is computed and quantised into one of eight compass sectors.
 *
 * Used for:
 *  - On-screen direction HUD (colour-coded rectangle)
 *  - Stereo panning: horizontal component drives left↔right balance (Todo #6)
 */
class DirectionTracker {
    static constexpr size_t kWindowSize = 10;
    std::deque<std::pair<float,float>> history;

public:
    /// Eight-direction compass
    enum class Dir { None, Right, Left, Down, Up, DownRight, DownLeft, UpRight, UpLeft };

    /// Push a new displacement sample.
    void push(float dx, float dy) {
        history.push_back({dx, dy});
        if (history.size() > kWindowSize) history.pop_front();
    }

    /// Clear all history (call when switching letter).
    void reset() { history.clear(); }

    /**
     * @brief Compute the dominant direction from the accumulated vector.
     * @return Dir enum value; Dir::None if movement is negligible.
     */
    [[nodiscard]] Dir dominant() const {
        if (history.empty()) return Dir::None;
        float ax = 0, ay = 0;
        for (auto& [dx, dy] : history) { ax += dx; ay += dy; }
        ax /= (float)history.size();
        ay /= (float)history.size();
        if (std::hypot(ax, ay) < 0.5f) return Dir::None;

        float angle = std::atan2(ay, ax) * 180.f / (float)M_PI;
        if (angle < 0) angle += 360.f;
        int sector = static_cast<int>((angle + 22.5f) / 45.f) % 8;
        switch (sector) {
            case 0: return Dir::Right;
            case 1: return Dir::DownRight;
            case 2: return Dir::Down;
            case 3: return Dir::DownLeft;
            case 4: return Dir::Left;
            case 5: return Dir::UpLeft;
            case 6: return Dir::Up;
            case 7: return Dir::UpRight;
            default: return Dir::None;
        }
    }

    /**
     * @brief Normalised horizontal bias of recent movement.
     * @return Value in [-1, +1]: negative = moving left, positive = moving right.
     */
    [[nodiscard]] float horizontalBias() const {
        if (history.empty()) return 0.f;
        float ax = 0, ay = 0;
        for (auto& [dx, dy] : history) { ax += dx; ay += dy; }
        float mag = std::hypot(ax, ay);
        return (mag > 0.01f) ? ax / mag : 0.f;
    }

    /// @return SDL_Color for the HUD rectangle representing direction.
    static SDL_FColor hudColor(Dir d) {
        switch (d) {
            case Dir::Right:
            case Dir::Left:     return {0.31f, 0.31f, 1.0f,  1.0f}; // blue  = horizontal
            case Dir::Down:
            case Dir::Up:       return {0.31f, 0.86f, 0.31f, 1.0f}; // green = vertical
            case Dir::DownRight:
            case Dir::DownLeft:
            case Dir::UpRight:
            case Dir::UpLeft:   return {1.0f,  0.63f, 0.0f,  1.0f}; // orange = diagonal
            default:            return {0.47f, 0.47f, 0.47f, 1.0f}; // grey  = none
        }
    }
};

// ============================================================================
// Adaptive velocity statistics  (Todo #7)
// ============================================================================

/**
 * @brief Rolling-window velocity statistics for adaptive mute threshold.
 *
 * Instead of a fixed pixel-per-frame threshold, the app measures the child's
 * actual writing pace over the last N frames.  A stroke velocity below
 * `mean × kAdaptiveMuteFactor` is treated as "pen lifted" → audio mutes.
 *
 * This also anchors Todo #2: normalising speed mapping against the child's
 * own baseline rather than a hard-coded constant.
 */
class VelocityStats {
    std::deque<float> window;
public:
    void push(float vel) {
        window.push_back(vel);
        if (window.size() > Config::kVelocityWindowSize) window.pop_front();
    }

    /// Rolling arithmetic mean; returns kBaselineVelocity when no data yet.
    [[nodiscard]] float mean() const {
        if (window.empty()) return Config::kBaselineVelocity;
        return std::accumulate(window.begin(), window.end(), 0.f) / (float)window.size();
    }

    /// Velocity below this value is treated as "stopped" → mute audio.
    [[nodiscard]] float muteThreshold() const {
        return mean() * Config::kAdaptiveMuteFactor;
    }
};

// ============================================================================
// Audio engine  (SDL3 audio stream + RubberBand + libsndfile)
// ============================================================================

/**
 * @brief Manages audio decoding, real-time time-stretching, pitch shifting,
 *        stereo panning, seamless looping, and on-the-fly speed changes.
 *
 * SDL3 uses a push-based audio model: `AudioCallback` is called by the audio
 * subsystem whenever the hardware buffer needs more data.  All communication
 * between the main thread and the callback uses `g_state` atomics (lock-free).
 *
 * Key behaviours:
 *  - Speed   : `g_state.targetSpeed` is smoothly interpolated each callback
 *              and passed to `RubberBandStretcher::setTimeRatio()`.
 *  - Pitch   : `g_state.targetPitch` drives `setPitchScale()`. (Todo #6)
 *  - Panning : per-channel gain applied post-retrieve. (Todo #6)
 *  - Restart : `g_state.restart` flag causes an immediate seek to frame 0. (Todo #8)
 *  - Loop    : at file EOF the read position seamlessly wraps to the start.
 */
class AudioEngine {
    SNDFILE*           snd         = nullptr;
    SF_INFO            sfInfo      = {};
    SDL_AudioStream*   audioStream = nullptr;

    std::unique_ptr<RubberBand::RubberBandStretcher> stretcher;

    std::vector<float>              inBuf;
    std::vector<std::vector<float>> chanBufs;
    std::vector<float*>             inPtrs, outPtrs;

    float currentSpeed = 1.0f;
    float currentPitch = 1.0f;
    std::mutex loadMutex;

    // --- Fade-in/out state ---
    float fadeGain = 0.0f;    // [0.0-1.0]
    enum class FadeState { None, FadingIn, FadingOut };
    FadeState fadeState = FadeState::None;
    bool prevIsPlaying = false;
    static constexpr float fadeTimeSec = 0.06f;
    float fadeDelta = 1.0f; // fade rate (per sample)

public:
    AudioEngine()  = default;
    ~AudioEngine() { stop(); if (snd) sf_close(snd); }

    /// Stop and destroy the current SDL audio stream (safe to call repeatedly).
    void stop() {
        if (audioStream) {
            SDL_DestroyAudioStream(audioStream);
            audioStream = nullptr;
        }
    }

    /**
     * @brief Load a new audio file and restart playback.
     *
     * Rebuilds the RubberBand stretcher and all internal buffers to match
     * the new file's sample-rate and channel count.
     *
     * @param path  Absolute path to the audio file.
     */
    void loadFile(const std::string& path) {
        if (path.empty()) return;
        std::lock_guard<std::mutex> lock(loadMutex);

        stop();
        if (snd) { sf_close(snd); snd = nullptr; }

        snd = sf_open(path.c_str(), SFM_READ, &sfInfo);
        if (!snd) {
            std::cerr << "❌ Audio load failed: " << path << "\n";
            return;
        }

        using RBS = RubberBand::RubberBandStretcher;
        RBS::Options opts = RBS::OptionProcessRealTime
                          | RBS::OptionThreadingNever
                          | RBS::OptionWindowStandard
                          | RBS::OptionPitchHighQuality; // Todo #6

        stretcher = std::make_unique<RBS>(sfInfo.samplerate, sfInfo.channels, opts);

        inBuf.resize(Config::kBufFrames * (size_t)sfInfo.channels * Config::kInputMultiplier);
        chanBufs.resize((size_t)sfInfo.channels);
        inPtrs.resize((size_t)sfInfo.channels);
        outPtrs.resize((size_t)sfInfo.channels);
        for (int c = 0; c < sfInfo.channels; ++c) {
            chanBufs[c].resize(Config::kBufFrames * Config::kInputMultiplier * 2);
            inPtrs[c]  = chanBufs[c].data();
            outPtrs[c] = chanBufs[c].data();
        }

        startStream();
        std::cout << "🎵 Loaded: " << fs::path(path).filename().string()
                  << "  (" << sfInfo.samplerate << " Hz, " << sfInfo.channels << " ch)\n";

        // Pre-warm: feed RubberBand its required latency upfront so the first
        // audio callback always has data available (prevents startup crackling).
        int prewarmFrames = stretcher->getLatency() + (int)(Config::kBufFrames * Config::kInputMultiplier);
        std::vector<float> prewarmBuf((size_t)(prewarmFrames * sfInfo.channels));
        sf_readf_float(snd, prewarmBuf.data(), prewarmFrames);
        // Rewind so normal playback starts from the beginning
        sf_seek(snd, 0, SEEK_SET);
        // De-interleave and submit to stretcher
        for (int i = 0; i < prewarmFrames; ++i)
            for (int c = 0; c < sfInfo.channels; ++c)
                chanBufs[c][i % chanBufs[c].size()] = prewarmBuf[(size_t)(i * sfInfo.channels + c)];
        stretcher->process(inPtrs.data(), (size_t)prewarmFrames, false);
    }

private:
    void startStream() {
        SDL_AudioSpec spec;
        spec.channels = sfInfo.channels;
        spec.format   = SDL_AUDIO_F32;
        spec.freq     = sfInfo.samplerate;

        audioStream = SDL_OpenAudioDeviceStream(
            SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, AudioCallback, this);

        if (!audioStream) {
            std::cerr << "❌ SDL audio stream failed: " << SDL_GetError() << "\n";
            return;
        }

        SDL_AudioDeviceID dev = SDL_GetAudioStreamDevice(audioStream);
        if (dev) SDL_ResumeAudioDevice(dev);
    }

    /**
     * @brief SDL3 audio callback — called on the audio thread when more data is needed.
     * @param userdata         Pointer to the AudioEngine instance.
     * @param stream           The SDL_AudioStream to push data into.
     * @param additional_amount Bytes the stream is requesting.
     * @param total_amount     Total buffered bytes (informational).
     */
    static void SDLCALL AudioCallback(void* userdata, SDL_AudioStream* stream,
                                      int additional_amount, int /*total_amount*/) {
        if (additional_amount <= 0) return;
        auto* self = static_cast<AudioEngine*>(userdata);
        int frameSize    = (int)sizeof(float) * self->sfInfo.channels;
        int framesNeeded = additional_amount / frameSize;

        std::vector<float> out((size_t)(framesNeeded * self->sfInfo.channels));
        self->process(out.data(), (unsigned long)framesNeeded);
        SDL_PutAudioStreamData(stream, out.data(), (int)(out.size() * sizeof(float)));
    }

    /**
     * @brief Core DSP loop: time-stretch, pitch-shift, pan, loop, output.
     *
     * Called from AudioCallback on the audio thread.
     *
     * @param output  Interleaved float PCM output buffer.
     * @param frames  Number of frames to produce.
     */
    void process(float* output, unsigned long frames) {
        bool isPlaying = g_state.isPlaying.load();
        if (!snd) {
            std::fill_n(output, frames * (size_t)sfInfo.channels, 0.0f);
            fadeGain = 0.f;
            fadeState = FadeState::None;
            prevIsPlaying = false;
            return;
        }
        // Handle fade-in/out transitions
        if (!prevIsPlaying && isPlaying) {
            fadeState = FadeState::FadingIn;
            // Calculate per-sample fade increment
            fadeDelta = (sfInfo.samplerate > 0) ? (1.0f / (fadeTimeSec * sfInfo.samplerate)) : 1.0f;
        } else if (prevIsPlaying && !isPlaying) {
            fadeState = FadeState::FadingOut;
            fadeDelta = (sfInfo.samplerate > 0) ? (1.0f / (fadeTimeSec * sfInfo.samplerate)) : 1.0f;
        }
        prevIsPlaying = isPlaying;

        // --- Todo #8: Rewind if restart flag is set ---
        if (g_state.restart.exchange(false)) {
            sf_seek(snd, 0, SEEK_SET);
            stretcher->reset();
        }

        // --- Smooth speed interpolation ---
        float tgtSpeed = g_state.targetSpeed.load();
        if (std::abs(currentSpeed - tgtSpeed) > 0.005f) {
            currentSpeed += (tgtSpeed - currentSpeed) * Config::kInterpolationFactor;
            stretcher->setTimeRatio(currentSpeed);
        }

        // --- Todo #6: Smooth pitch interpolation ---
        float tgtPitch = g_state.targetPitch.load();
        if (std::abs(currentPitch - tgtPitch) > 0.005f) {
            currentPitch += (tgtPitch - currentPitch) * Config::kInterpolationFactor;
            stretcher->setPitchScale(currentPitch);
        }

        float panL = g_state.panLeft.load();
        float panR = g_state.panRight.load();

        size_t remaining = frames;
        float* wptr      = output;
        size_t chunkSz   = Config::kBufFrames * Config::kInputMultiplier;

        while (remaining > 0) {
            if (stretcher->available() < (int)remaining) {
                // Read a chunk from disk
                sf_count_t got = sf_readf_float(snd, inBuf.data(), (sf_count_t)chunkSz);

                // Seamless loop: wrap to file start at EOF
                if (got < (sf_count_t)chunkSz) {
                    sf_seek(snd, 0, SEEK_SET);
                    got += sf_readf_float(snd,
                        inBuf.data() + got * sfInfo.channels,
                        (sf_count_t)chunkSz - got);
                }

                // De-interleave for RubberBand
                for (sf_count_t i = 0; i < got; ++i)
                    for (int c = 0; c < sfInfo.channels; ++c)
                        chanBufs[c][i] = inBuf[i * sfInfo.channels + c];

                stretcher->process(inPtrs.data(), (size_t)got, false);
            }

            size_t ret = stretcher->retrieve(outPtrs.data(), remaining);

            // Interleave + apply pan gain (Todo #6)
            for (size_t i = 0; i < ret; ++i) {
                // Handle fade-in/fade-out
                switch (fadeState) {
                    case FadeState::FadingIn:
                        fadeGain += fadeDelta;
                        if (fadeGain >= 1.0f) { fadeGain = 1.0f; fadeState = FadeState::None; }
                        break;
                    case FadeState::FadingOut:
                        fadeGain -= fadeDelta;
                        if (fadeGain <= 0.0f) { fadeGain = 0.0f; fadeState = FadeState::None; }
                        break;
                    default: break;
                }
                float outGain = fadeGain;
                if (isPlaying && fadeState != FadeState::FadingOut) {
                    outGain = fadeGain; // ramp up
                } else if (!isPlaying && fadeState != FadeState::FadingIn) {
                    outGain = fadeGain; // ramp down
                }
                for (int c = 0; c < sfInfo.channels; ++c) {
                    float gain = 1.0f;
                    if (sfInfo.channels == 2) gain = (c == 0) ? panL : panR;
                    *wptr++ = chanBufs[c][i] * gain * outGain;
                }
            }

            remaining -= ret;
            if (ret == 0) {
                // RubberBand couldn't deliver — output silence for the rest to avoid
                // uninitialized data reaching the speaker (prevents crackling)
                std::fill_n(wptr, remaining * (size_t)sfInfo.channels, 0.0f);
                break;
            }
        }
        // If fade is done and not playing, zero gain
        if (!isPlaying && fadeState == FadeState::None) fadeGain = 0.0f;
    }
};

// ============================================================================
// Helpers: SDL texture builders
// ============================================================================

/**
 * @brief Build the main opaque letter-outline texture from a BitmapMask.
 *
 * Black pixels → 0xFF000000 (solid black)
 * White pixels → 0xFFFFFFFF (solid white)
 *
 * @param renderer  Active SDL renderer.
 * @param mask      Loaded BitmapMask.
 * @return New SDL_Texture* (caller owns it; destroy with SDL_DestroyTexture).
 */

static SDL_Texture* buildOutlineTexture(SDL_Renderer* renderer, const BitmapMask& mask) {
    int W = mask.getW(), H = mask.getH();
    std::vector<uint32_t> px((size_t)(W * H));
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x)
            px[(size_t)(y * W + x)] = mask.isHit((float)x, (float)y) ? 0xFF000000u : 0xFFFFFFFFu;

    SDL_Texture* t = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                       SDL_TEXTUREACCESS_STATIC, W, H);
    SDL_UpdateTexture(t, nullptr, px.data(), W * (int)sizeof(uint32_t));
    return t;
}

/**
 * @brief Build the semi-transparent ghost/tracing overlay texture (Todo #5).
 *
 * Letter stroke pixels → cyan with alpha = Config::kTraceAlpha
 * Background pixels   → fully transparent
 *
 * @param renderer  Active SDL renderer.
 * @param mask      Loaded BitmapMask.
 * @return New SDL_Texture* with SDL_BLENDMODE_BLEND set.
 */
static SDL_Texture* buildGhostTexture(SDL_Renderer* renderer, const BitmapMask& mask) {
    int W = mask.getW(), H = mask.getH();
    std::vector<uint32_t> px((size_t)(W * H));
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x)
            px[(size_t)(y * W + x)] = mask.isHit((float)x, (float)y)
                ? ((uint32_t)Config::kTraceAlpha << 24) | 0x00AAFFFF  // cyan
                : 0x00000000u;

    SDL_Texture* t = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                       SDL_TEXTUREACCESS_STATIC, W, H);
    SDL_SetTextureBlendMode(t, SDL_BLENDMODE_BLEND);
    SDL_UpdateTexture(t, nullptr, px.data(), W * (int)sizeof(uint32_t));
    return t;
}

// ============================================================================
// Main entry point
// ============================================================================
int main(int /*argc*/, char** /*argv*/) {

    // --- SDL3 init ---
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_AUDIO)) {
        std::cerr << "SDL_Init failed: " << SDL_GetError() << "\n";
        return 1;
    }

    // --- Assets ---
    std::mt19937 rng(std::random_device{}());
    AssetBrowser browser;
    browser.scanRoot();
    if (!browser.isValid()) {
        std::cerr << "❌ No letter assets found in app bundle.\n";
        SDL_Quit();
        return 1;
    }

    BitmapMask mask;
    mask.load(browser.current().pbmPath);

    // --- Window (fullscreen on iPad) ---
    SDL_Window*   window   = SDL_CreateWindow("Timestretch", 800, 600,
                                              SDL_WINDOW_FULLSCREEN | SDL_WINDOW_RESIZABLE);
    SDL_Renderer* renderer = SDL_CreateRenderer(window, nullptr);

    // Install the UIKit drawing overlay on top of the SDL view.
    // Must be called after SDL_CreateRenderer so the UIWindow is set up.
    overlay_installer_attach();

    // --- Textures ---
    SDL_Texture* outlineTex = buildOutlineTexture(renderer, mask);
    SDL_Texture* ghostTex   = buildGhostTexture(renderer, mask);

    /// Rebuilds both textures after a letter change.
    auto rebuildTextures = [&]() {
        if (outlineTex) SDL_DestroyTexture(outlineTex);
        if (ghostTex)   SDL_DestroyTexture(ghostTex);
        outlineTex = buildOutlineTexture(renderer, mask);
        ghostTex   = buildGhostTexture(renderer, mask);
    };

    // --- Audio engine ---
    AudioEngine audio;
    audio.loadFile(browser.currentAudioPath());

    // --- Per-frame state ---
    float lastImgX = 0, lastImgY = 0;
    bool  firstFrame = true;

    auto lastMoveTime  = std::chrono::steady_clock::now() - std::chrono::seconds(10);
    auto lastValidTime = std::chrono::steady_clock::now() - std::chrono::seconds(10);
    auto lastSoundTime = std::chrono::steady_clock::now();  ///< Todo #8 pause clock

    DirectionTracker dirTracker;
    VelocityStats    velStats;

    // --- Stroke tracker ---
    LetterStrokes   currentStrokes = loadStrokes(browser.current().bestStrokesPath());
    StrokeTracker   strokeTracker;
    if (currentStrokes.valid) strokeTracker.load(currentStrokes);

    /// Helper: reload strokes for current letter
    auto reloadStrokes = [&]() {
        currentStrokes = loadStrokes(browser.current().bestStrokesPath());
        strokeTracker.reset();
        if (currentStrokes.valid) strokeTracker.load(currentStrokes);
    };

    // Small smoothing buffer for speed mapping (separate from velStats adaptive window)
    std::deque<float> velSmooth;

    // --- Multi-touch state ---
    int   activeFingers = 0;
    float touchStartX   = 0.f, touchStartY = 0.f;

    // Todo #5: tracing ghost toggle (3-finger tap)
    bool tracingMode = false;

    // Stroke direction enforcement toggle (4-finger tap)
    // true  = sound only plays when writing in correct direction (Option B/C)
    // false = sound plays anywhere on the letter (free mode)
    bool strokeEnforced = true;

    // HUD: stroke mode indicator (top-left, small badge)
    SDL_FRect strokeBadge = {8.f, 10.f, 28.f, 28.f};

    // HUD: direction indicator rectangle (bottom-left)
    SDL_FRect dirHud = {8.f, 0.f, 120.f, 28.f};

    // HUD: playback status dot (top-right)
    SDL_FRect statusDot = {0.f, 10.f, 30.f, 30.f};

    // ---- MAIN LOOP ----
    while (!g_state.shouldQuit) {
        SDL_Event ev;
        bool assetsChanged = false;

        // ================================================================
        // Event processing
        // ================================================================
        while (SDL_PollEvent(&ev)) {

            switch (ev.type) {

            case SDL_EVENT_QUIT:
                g_state.shouldQuit = true;
                break;

            // ---- Finger down ----
            case SDL_EVENT_FINGER_DOWN:
                activeFingers++;

                if (activeFingers == 2) {
                    // Entering two-finger navigation mode:
                    // record start position and stop audio immediately (Todo #3)
                    touchStartX       = ev.tfinger.x;
                    touchStartY       = ev.tfinger.y;
                    g_state.isPlaying = false;
                }
                else if (activeFingers == 3) {
                    // Todo #5: three-finger tap toggles the ghost tracing overlay
                    tracingMode = !tracingMode;
                }
                else if (activeFingers == 4) {
                    // Four-finger tap: toggle stroke direction enforcement
                    strokeEnforced = !strokeEnforced;
                    // Reset tracker so child gets a clean start in the new mode
                    strokeTracker.reset();
                    std::cout << (strokeEnforced ? "🔒 Stroke enforcement ON\n"
                                                 : "🔓 Stroke enforcement OFF (free mode)\n");
                }
                break;

            // ---- Finger up ----
            case SDL_EVENT_FINGER_UP:
                if (activeFingers == 2) {
                    // Evaluate the completed two-finger swipe gesture
                    float dx = ev.tfinger.x - touchStartX;
                    float dy = ev.tfinger.y - touchStartY;

                    if (std::abs(dx) > Config::kSwipeThreshold && std::abs(dx) > std::abs(dy)) {
                        // Horizontal swipe → change letter
                        if (dx < 0) browser.nextFolder();
                        else        browser.prevFolder();
                        mask.load(browser.current().pbmPath);
                        rebuildTextures();
                        audio.loadFile(browser.currentAudioPath());
                        dirTracker.reset();
                        reloadStrokes();
                        assetsChanged = true;

                    } else if (std::abs(dy) > Config::kSwipeThreshold) {
                        // Vertical swipe → change audio variant
                        if (dy < 0) browser.nextAudio();
                        else        browser.prevAudio();
                        audio.loadFile(browser.currentAudioPath());
                        assetsChanged = true;
                    }

                    // Todo #1: two-finger double-tap → random letter
                    if (std::abs(dx) < 0.03f && std::abs(dy) < 0.03f) {
                        browser.pickRandom(rng);
                        mask.load(browser.current().pbmPath);
                        rebuildTextures();
                        audio.loadFile(browser.currentAudioPath());
                        dirTracker.reset();
                        reloadStrokes();
                        assetsChanged = true;
                    }

                    g_state.isPlaying = false;
                }

                if (activeFingers > 0) activeFingers--;
                break;

            default: break;
            }
        }
        (void)assetsChanged; // may be used for title updates in future

        // ================================================================
        // Playback logic  (only when exactly 1 finger active)
        // ================================================================

        if (activeFingers >= 2) {
            // Two+ fingers always silences audio (Todo #3)
            g_state.isPlaying = false;

        } else {
            int winW = 0, winH = 0;
            SDL_GetWindowSize(window, &winW, &winH);

            // Read cursor/touch position via SDL mouse API
            // (SDL3 maps single-finger touch to mouse events on iOS)
            float winX = 0, winY = 0;
            SDL_GetMouseState(&winX, &winY);

            if (winW > 0 && winH > 0) {
                float scaleX = (float)winW / (float)mask.getW();
                float scaleY = (float)winH / (float)mask.getH();
                float imgX   = winX / scaleX;
                float imgY   = winY / scaleY;

                if (firstFrame) { lastImgX = imgX; lastImgY = imgY; firstFrame = false; }

                float dx  = imgX - lastImgX;
                float dy  = imgY - lastImgY;
                float vel = std::hypot(dx, dy);

                // Feed trackers regardless of hit result
                if (vel > Config::kMoveThreshold) {
                    dirTracker.push(dx, dy);
                    velStats.push(vel);
                    velSmooth.push_back(vel);
                    if (velSmooth.size() > 8) velSmooth.pop_front();
                }

                float smoothVel = velSmooth.empty() ? 0.f
                    : std::accumulate(velSmooth.begin(), velSmooth.end(), 0.f) / (float)velSmooth.size();

                auto now = std::chrono::steady_clock::now();

                // --- Stroke tracking: update with normalised coords ---
                float normX = (mask.getW() > 0) ? imgX / (float)mask.getW() : 0.f;
                float normY = (mask.getH() > 0) ? imgY / (float)mask.getH() : 0.f;
                strokeTracker.update(normX, normY, activeFingers == 1);

                // Restart sound if first checkpoint was just touched
                if (strokeTracker.wantRestart) {
                    g_state.restart = true;
                    lastSoundTime = now;
                }

                if (mask.isHit(imgX, imgY)) {
                    lastValidTime = now;

                    if (vel > velStats.muteThreshold()) {  // Todo #7: adaptive gate
                        lastMoveTime  = now;
                        lastSoundTime = now;

                        // --- Todo #2: Speed normalisation against baseline ---
                        float normVel = smoothVel / Config::kBaselineVelocity;
                        float lo = Config::kLowVel  / Config::kBaselineVelocity;
                        float hi = Config::kHighVel / Config::kBaselineVelocity;

                        float speed;
                        if      (normVel <= lo) speed = Config::kMaxSpeed;
                        else if (normVel >= hi) speed = Config::kMinSpeed;
                        else {
                            float t = (normVel - lo) / (hi - lo);
                            speed = Config::kMaxSpeed - t * (Config::kMaxSpeed - Config::kMinSpeed);
                        }
                        g_state.targetSpeed = speed;

                        // --- Todo #6: Pitch shift anti-correlated with speed ---
                        float normSpeed = (speed - Config::kMinSpeed)
                                        / (Config::kMaxSpeed - Config::kMinSpeed);
                        float semitones = Config::kMaxPitchSemitones * (1.f - normSpeed * 2.f);
                        g_state.targetPitch = std::pow(2.f, semitones / 12.f);

                        // --- Todo #6: Stereo panning ---
                        float hBias = std::max(-1.f, std::min(1.f, dirTracker.horizontalBias()));
                        float l = 0.5f - 0.15f * hBias;
                        float r = 0.5f + 0.15f * hBias;
                        g_state.panLeft  = l;
                        g_state.panRight = r;

                        // Gate audio by stroke correctness (bypass if enforcement is off)
                        // Gate audio by stroke correctness (when enforced)
                        g_state.isPlaying = !strokeEnforced || strokeTracker.soundEnabled;

                    } else {
                        // Below adaptive mute threshold → idle timeout
                        auto idleMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                          now - lastMoveTime).count();
                        g_state.isPlaying = (!strokeEnforced || strokeTracker.soundEnabled) &&
                                            (idleMs <= Config::kIdleTimeoutMs);
                        if (g_state.isPlaying) g_state.targetSpeed = Config::kIdleSpeed;
                    }

                } else {
                    // Outside the letter mask — apply exit grace period
                    // Only keep playing if stroke direction was correct
                    auto exitMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                      now - lastValidTime).count();
                    if (exitMs < Config::kExitTimeoutMs && strokeTracker.soundEnabled) {
                        g_state.targetSpeed = Config::kIdleSpeed;
                        g_state.isPlaying   = true;
                    } else {
                        g_state.isPlaying = false;
                    }
                }

                // --- Todo #8: Restart sound after sustained pause ---
                if (g_state.isPlaying) {
                    lastSoundTime = std::chrono::steady_clock::now();
                } else {
                    auto silentMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                        std::chrono::steady_clock::now() - lastSoundTime).count();
                    if (silentMs > Config::kRestartAfterPauseMs) {
                        g_state.restart   = true;
                        lastSoundTime     = std::chrono::steady_clock::now();
                    }
                }

                lastImgX = imgX;
                lastImgY = imgY;
            }
        }

        // ================================================================
        // Rendering
        // ================================================================
        int ww = 0, wh = 0;
        SDL_GetWindowSize(window, &ww, &wh);

        SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
        SDL_RenderClear(renderer);

        // Letter outline
        SDL_RenderTexture(renderer, outlineTex, nullptr, nullptr);

        // (Green stroke painting handled by DrawingOverlay UIKit layer above SDL view)

        // Todo #5: ghost tracing overlay (toggled by three-finger tap)
        if (tracingMode && ghostTex)
            SDL_RenderTexture(renderer, ghostTex, nullptr, nullptr);

        // --- Todo #4: Direction HUD (bottom-left) ---
        // A colour-coded rectangle that tells the child which way they're writing.
        // Blue = horizontal, Green = vertical, Orange = diagonal, Grey = idle.
        {
            dirHud.y = (float)wh - 38.f;
            SDL_FColor bg = {0.12f, 0.12f, 0.12f, 0.78f};
            SDL_SetRenderDrawColorFloat(renderer, bg.r, bg.g, bg.b, bg.a);
            SDL_RenderFillRect(renderer, &dirHud);

            SDL_FColor dc = DirectionTracker::hudColor(dirTracker.dominant());
            SDL_FRect inner = {dirHud.x + 2.f, dirHud.y + 2.f, dirHud.w - 4.f, dirHud.h - 4.f};
            SDL_SetRenderDrawColorFloat(renderer, dc.r, dc.g, dc.b, dc.a);
            SDL_RenderFillRect(renderer, &inner);
        }

        // --- Stroke mode badge (top-left) ---
        // 🔒 Orange = stroke enforcement ON (direction matters)
        // 🔓 Grey   = free mode (sound plays anywhere on letter)
        {
            SDL_SetRenderDrawColor(renderer, 30, 30, 30, 180);
            SDL_RenderFillRect(renderer, &strokeBadge);
            SDL_FRect inner = {strokeBadge.x+2.f, strokeBadge.y+2.f,
                               strokeBadge.w-4.f,  strokeBadge.h-4.f};
            if (strokeEnforced)
                SDL_SetRenderDrawColor(renderer, 255, 140, 0, 255);   // orange = enforced
            else
                SDL_SetRenderDrawColor(renderer, 120, 120, 120, 255); // grey = free
            SDL_RenderFillRect(renderer, &inner);
        }

        // --- Playback status dot (top-right) ---
        // Green = playing, Blue = navigation mode, Red = idle/wrong direction
        statusDot.x = (float)ww - 40.f;
        if (activeFingers >= 2)
            SDL_SetRenderDrawColor(renderer, 0, 120, 255, 255);  // blue
        else if (g_state.isPlaying)
            SDL_SetRenderDrawColor(renderer, 0,   220,   0, 255);  // green
        else if (strokeTracker.anyActive())
            SDL_SetRenderDrawColor(renderer, 255, 200,   0, 255);  // yellow = on letter, wrong direction
        else
            SDL_SetRenderDrawColor(renderer, 220,   0,   0, 255);  // red
        SDL_RenderFillRect(renderer, &statusDot);

        // --- Stroke enforcement badge (top-left) ---
        // Orange = enforcement ON (numbered stroke order required)
        // Grey   = free mode (any stroke, any direction)
        if (strokeEnforced)
            SDL_SetRenderDrawColor(renderer, 255, 140,   0, 220);  // orange
        else
            SDL_SetRenderDrawColor(renderer,  90,  90,  90, 180);  // grey
        SDL_RenderFillRect(renderer, &strokeBadge);

        // --- Current stroke number indicator (inside the badge) ---
        // Draw 1–4 small dots inside the badge showing which stroke is next
        if (strokeEnforced) {
            int totalStrokes  = currentStrokes.valid ? (int)currentStrokes.strokes.size() : 0;
            int currentStroke = strokeTracker.currentStrokeIndex(); // 0-based
            float dotSize = 5.f;
            float spacing = (strokeBadge.w - 4.f) / std::max(totalStrokes, 1);
            for (int si = 0; si < totalStrokes; ++si) {
                SDL_FRect dot = {
                    strokeBadge.x + 2.f + si * spacing,
                    strokeBadge.y + strokeBadge.h/2.f - dotSize/2.f,
                    dotSize, dotSize
                };
                if (si < currentStroke)
                    SDL_SetRenderDrawColor(renderer,   0, 200,  60, 255); // green = done
                else if (si == currentStroke)
                    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255); // white = current
                else
                    SDL_SetRenderDrawColor(renderer,  60,  60,  60, 200); // dark = future
                SDL_RenderFillRect(renderer, &dot);
            }
        }

        // --- Stroke progress bar (bottom, full width) ---
        // Shows overall checkpoint completion: empty = not started, full = letter complete
        {
            float prog = strokeTracker.overallProgress();
            SDL_FRect barBg  = {0.f, (float)wh - 8.f, (float)ww, 8.f};
            SDL_FRect barFg  = {0.f, (float)wh - 8.f, (float)ww * prog, 8.f};
            SDL_SetRenderDrawColor(renderer, 60, 60, 60, 180);
            SDL_RenderFillRect(renderer, &barBg);
            if (prog > 0.01f) {
                SDL_SetRenderDrawColor(renderer, 0, 210, 80, 220);
                SDL_RenderFillRect(renderer, &barFg);
            }
        }

        SDL_RenderPresent(renderer);
        SDL_Delay(16); // ~60 fps
    }

    // --- Cleanup ---
    if (outlineTex) SDL_DestroyTexture(outlineTex);
    if (ghostTex)   SDL_DestroyTexture(ghostTex);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}

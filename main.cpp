/**
 * @file main.mm
 * @brief Timestretch for iPadOS (SDL3 Audio Version)
 * Removes PortAudio dependency in favor of native SDL3 Audio.
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

// SDL3 Headers
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h> 

// Audio Processing Libs
#include <sndfile.h>
#include <rubberband/RubberBandStretcher.h>

namespace fs = std::filesystem;

// ============================================================================
// Config
// ============================================================================
namespace Config {
    constexpr float kMinSpeed = 0.5f;       
    constexpr float kMaxSpeed = 2.0f;       
    constexpr float kIdleSpeed = 1.0f;      
    constexpr float kLowVel = 5.0f;         
    constexpr float kHighVel = 50.0f;
    constexpr size_t kBufFrames = 1024;
    constexpr size_t kInputMultiplier = 4; 
    constexpr float kInterpolationFactor = 0.15f; 
    constexpr int kIdleTimeoutMs = 800; 
    constexpr int kExitTimeoutMs = 400;
    constexpr float kMoveThreshold = 0.5f;
}

// ============================================================================
// Global State
// ============================================================================
struct SharedState {
    std::atomic<float> targetSpeed{1.0f};
    std::atomic<bool> isPlaying{false};
    std::atomic<bool> shouldQuit{false};
};
SharedState g_state;

// ============================================================================
// File Browser (iOS Path Fixed)
// ============================================================================
struct LetterFolder {
    std::string name;
    std::string path;
    std::string pbmPath;
    std::vector<std::string> audioFiles; 
    int currentAudioIdx = 0;
};

class AssetBrowser {
public:
    std::vector<LetterFolder> folders;
    int currentFolderIdx = 0;

    void scanRoot(std::string rootPath = "") {
        folders.clear();
        
        // --- iOS Path Logic ---
        if (rootPath.empty()) {
            const char* basePath = SDL_GetBasePath();
            rootPath = basePath ? std::string(basePath) : ".";
            // SDL3 manages the pointer lifetime usually, but standard string copy is safe
        }
        // ----------------------

        const std::vector<std::string> audExts = {".wav", ".mp3", ".flac", ".ogg", ".aiff"};

        try {
            for (const auto& entry : fs::directory_iterator(rootPath)) {
                if (!entry.is_directory()) continue;

                LetterFolder folder;
                folder.path = entry.path().string();
                folder.name = entry.path().filename().string();
                bool hasPBM = false;

                for (const auto& subEntry : fs::directory_iterator(folder.path)) {
                    if (!subEntry.is_regular_file()) continue;
                    std::string ext = subEntry.path().extension().string();
                    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

                    if (ext == ".pbm") {
                        folder.pbmPath = subEntry.path().string();
                        hasPBM = true;
                    } else {
                        for (const auto& ae : audExts) {
                            if (ext == ae) {
                                folder.audioFiles.push_back(subEntry.path().string());
                                break;
                            }
                        }
                    }
                }
                if (hasPBM) {
                    std::sort(folder.audioFiles.begin(), folder.audioFiles.end());
                    folders.push_back(folder);
                }
            }
            std::sort(folders.begin(), folders.end(), [](const LetterFolder& a, const LetterFolder& b) {
                return a.name < b.name;
            });
        } catch (...) { std::cerr << "⚠️  Filesystem Error.\n"; }
    }

    bool isValid() const { return !folders.empty(); }
    LetterFolder& getCurrentFolder() { return folders[currentFolderIdx]; }
    
    std::string getCurrentAudio() {
        auto& f = folders[currentFolderIdx];
        if (f.audioFiles.empty()) return "";
        return f.audioFiles[f.currentAudioIdx];
    }

    void nextFolder() { if (!folders.empty()) currentFolderIdx = (currentFolderIdx + 1) % folders.size(); }
    void prevFolder() { if (!folders.empty()) currentFolderIdx = (currentFolderIdx - 1 + folders.size()) % folders.size(); }
    void nextAudio() {
        if (folders.empty()) return;
        auto& f = folders[currentFolderIdx];
        if (!f.audioFiles.empty()) f.currentAudioIdx = (f.currentAudioIdx + 1) % f.audioFiles.size();
    }
    void prevAudio() {
        if (folders.empty()) return;
        auto& f = folders[currentFolderIdx];
        if (!f.audioFiles.empty()) f.currentAudioIdx = (f.currentAudioIdx - 1 + f.audioFiles.size()) % f.audioFiles.size();
    }
};

// ============================================================================
// Audio Engine (SDL3 Version)
// ============================================================================
class AudioEngine {
    SNDFILE* snd = nullptr;
    SF_INFO sfInfo = {};
    SDL_AudioStream* audioStream = nullptr; // SDL3 Stream
    std::unique_ptr<RubberBand::RubberBandStretcher> stretcher;
    
    std::vector<float> inBuf;
    std::vector<std::vector<float>> chanBufs;
    std::vector<float*> inPtrs, outPtrs;
    
    float currentSpeed = 1.0f;
    std::mutex audioMutex;

public:
    AudioEngine() {
        // SDL Init handles Audio subsystem
    }
    
    ~AudioEngine() { 
        stop(); 
        if (snd) sf_close(snd); 
    }

    void stop() {
        if (audioStream) {
            SDL_DestroyAudioStream(audioStream);
            audioStream = nullptr;
        }
    }

    void loadFile(const std::string& path) {
        if (path.empty()) return;
        std::lock_guard<std::mutex> lock(audioMutex);
        
        stop();
        if (snd) { sf_close(snd); snd = nullptr; }

        snd = sf_open(path.c_str(), SFM_READ, &sfInfo);
        if (!snd) {
            std::cerr << "❌ Audio Load Failed: " << path << "\n";
            return;
        }

        // --- RubberBand Setup ---
        RubberBand::RubberBandStretcher::Options options = 
            RubberBand::RubberBandStretcher::OptionProcessRealTime |
            RubberBand::RubberBandStretcher::OptionThreadingNever |
            RubberBand::RubberBandStretcher::OptionWindowStandard;
            
        stretcher = std::make_unique<RubberBand::RubberBandStretcher>(
            sfInfo.samplerate, sfInfo.channels, options);

        // --- Buffer Setup ---
        inBuf.resize(Config::kBufFrames * sfInfo.channels * Config::kInputMultiplier);
        chanBufs.resize(sfInfo.channels);
        inPtrs.resize(sfInfo.channels);
        outPtrs.resize(sfInfo.channels);
        
        for (size_t i = 0; i < sfInfo.channels; ++i) {
            chanBufs[i].resize(Config::kBufFrames * Config::kInputMultiplier * 2);
            inPtrs[i] = chanBufs[i].data();
            outPtrs[i] = chanBufs[i].data();
        }

        startStream();
        std::cout << "🎵 Loaded: " << fs::path(path).filename().string() << "\n";
    }

private:
    void startStream() {
        // --- SDL3 Audio Stream Setup ---
        SDL_AudioSpec spec;
        spec.channels = sfInfo.channels;
        spec.format = SDL_AUDIO_F32; // Float 32-bit (matches PortAudio/Rubberband)
        spec.freq = sfInfo.samplerate;

        // Open Default Playback Device
        audioStream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, AudioCallback, this);
        
        if (!audioStream) {
            std::cerr << "❌ SDL Audio Stream Failed: " << SDL_GetError() << "\n";
            return;
        }

        SDL_ResumeAudioDeviceStream(audioStream);
    }

    // SDL3 Audio Callback
    static void SDLCALL AudioCallback(void *userdata, SDL_AudioStream *stream, int additional_amount, int total_amount) {
        if (additional_amount > 0) {
            // We need to provide 'additional_amount' bytes of data
            // Convert bytes to Frames (sizeof(float) * channels)
            AudioEngine* engine = (AudioEngine*)userdata;
            int frameSize = sizeof(float) * engine->sfInfo.channels;
            int framesNeeded = additional_amount / frameSize;
            
            // Generate audio into a temp buffer
            std::vector<float> outputBuffer(framesNeeded * engine->sfInfo.channels);
            
            engine->process(outputBuffer.data(), framesNeeded);
            
            // Push data to SDL stream
            SDL_PutAudioStreamData(stream, outputBuffer.data(), outputBuffer.size() * sizeof(float));
        }
    }

    // Identical processing logic, now called by SDL callback
    void process(float* output, unsigned long frames) {
        if (!g_state.isPlaying) {
            std::fill_n(output, frames * sfInfo.channels, 0.0f);
            return;
        }

        float target = g_state.targetSpeed;
        if (std::abs(currentSpeed - target) > 0.01f) {
            currentSpeed += (target - currentSpeed) * Config::kInterpolationFactor;
            stretcher->setTimeRatio(currentSpeed);
        }

        size_t framesNeeded = frames;
        float* outWrite = output;
        size_t readChunkSize = Config::kBufFrames * Config::kInputMultiplier;

        while (framesNeeded > 0) {
            int available = stretcher->available();
            if (available < (int)framesNeeded) {
                sf_count_t read = sf_readf_float(snd, inBuf.data(), readChunkSize);
                if (read < (sf_count_t)readChunkSize) {
                    sf_seek(snd, 0, SEEK_SET);
                    sf_count_t needed = readChunkSize - read;
                    sf_count_t looped = sf_readf_float(snd, inBuf.data() + (read * sfInfo.channels), needed);
                    read += looped;
                }
                for (size_t i = 0; i < read; ++i) {
                    for (int c = 0; c < sfInfo.channels; ++c) {
                        chanBufs[c][i] = inBuf[i * sfInfo.channels + c];
                    }
                }
                stretcher->process(inPtrs.data(), read, false);
            }
            size_t ret = stretcher->retrieve(outPtrs.data(), framesNeeded);
            for (size_t i = 0; i < ret; ++i) {
                for (int c = 0; c < sfInfo.channels; ++c) {
                    *outWrite++ = chanBufs[c][i];
                }
            }
            framesNeeded -= ret;
            if (ret == 0 && available == 0) break; 
        }
    }
};

// ============================================================================
// Bitmap Mask (SDL3 Coordinates Updated)
// ============================================================================
class BitmapMask {
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;

public:
    bool load(const std::string& path) {
        if (path.empty()) return false;
        std::ifstream file(path, std::ios::binary);
        if (!file) return false;

        std::string line;
        if (!(file >> line) || line != "P4") return false;
        while (file >> std::ws && file.peek() == '#') std::getline(file, line);
        if (!(file >> width >> height)) return false;
        file.get(); 

        int rowBytes = (width + 7) / 8;
        size_t dataSize = static_cast<size_t>(rowBytes * height);
        pixels.resize(dataSize);
        file.read(reinterpret_cast<char*>(pixels.data()), static_cast<long>(dataSize));
        return true;
    }

    // Accepts floats for SDL3 compatibility
    [[nodiscard]] bool isHit(float x, float y) const {
        int ix = static_cast<int>(x);
        int iy = static_cast<int>(y);
        if (ix < 0 || iy < 0 || ix >= width || iy >= height) return false;
        int rowBytes = (width + 7) / 8;
        int byteIndex = (iy * rowBytes) + (ix / 8);
        return (pixels[static_cast<size_t>(byteIndex)] >> (7 - (ix % 8))) & 1; 
    }

    [[nodiscard]] int getW() const { return width; }
    [[nodiscard]] int getH() const { return height; }
};

// ============================================================================
// Main Loop (SDL3 Updated)
// ============================================================================
int main(int argc, char** argv) {
    // SDL3 Init
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_AUDIO)) {
        std::cerr << "Init Error: " << SDL_GetError() << "\n";
        return 1;
    }

    AssetBrowser browser;
    browser.scanRoot(); // No argument needed, uses BasePath internally

    BitmapMask mask;
    if (browser.isValid()) mask.load(browser.getCurrentFolder().pbmPath);
    else { std::cerr << "❌ No assets found in App Bundle!\n"; return 1; }

    int startW = mask.getW() / 2;
    int startH = mask.getH() / 2;
    if (startW < 400) startW = 800;
    if (startH < 300) startH = 600;

    SDL_Window* window = SDL_CreateWindow("Timestretch", startW, startH, SDL_WINDOW_RESIZABLE);
    SDL_Renderer* renderer = SDL_CreateRenderer(window, NULL);

    SDL_Texture* texture = nullptr;
    auto updateTexture = [&](BitmapMask& m) {
        if (texture) SDL_DestroyTexture(texture);
        std::vector<uint32_t> texPixels(m.getW() * m.getH());
        for(int y=0; y<m.getH(); ++y) {
            for(int x=0; x<m.getW(); ++x) {
                texPixels[y * m.getW() + x] = m.isHit((float)x, (float)y) ? 0xFF000000 : 0xFFFFFFFF; 
            }
        }
        // SDL3 texture creation (API is slightly cleaner but essentially same)
        texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, m.getW(), m.getH());
        SDL_UpdateTexture(texture, NULL, texPixels.data(), m.getW() * sizeof(uint32_t));
    };
    updateTexture(mask);

    AudioEngine engine;
    if (browser.isValid()) engine.loadFile(browser.getCurrentAudio());

    float lastImgX = 0, lastImgY = 0;
    auto lastMoveTime = std::chrono::steady_clock::now() - std::chrono::seconds(10);
    auto lastValidTime = std::chrono::steady_clock::now() - std::chrono::seconds(10);
    
    bool showDebug = false;
    SDL_FRect statusDot = {0, 0, 30, 30}; // Float Rect for SDL3

    while (!g_state.shouldQuit) {
        SDL_Event e;
        bool assetsChanged = false;

        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_EVENT_QUIT) g_state.shouldQuit = true;
            // SDL3 key events
            else if (e.type == SDL_EVENT_KEY_DOWN) {
                switch(e.key.key) {
                    case SDLK_D: showDebug = !showDebug; break;
                    case SDLK_RIGHT: 
                        browser.nextFolder(); mask.load(browser.getCurrentFolder().pbmPath);
                        updateTexture(mask); engine.loadFile(browser.getCurrentAudio());
                        assetsChanged = true; break;
                    case SDLK_LEFT: 
                        browser.prevFolder(); mask.load(browser.getCurrentFolder().pbmPath);
                        updateTexture(mask); engine.loadFile(browser.getCurrentAudio());
                        assetsChanged = true; break;
                    case SDLK_UP: 
                        browser.nextAudio(); engine.loadFile(browser.getCurrentAudio());
                        assetsChanged = true; break;
                    case SDLK_DOWN: 
                        browser.prevAudio(); engine.loadFile(browser.getCurrentAudio());
                        assetsChanged = true; break;
                }
            }
        }

        if (assetsChanged && showDebug) {
             std::cout << "Loaded: " << browser.getCurrentFolder().name << "\n";
        }

        int winW, winH;
        SDL_GetWindowSize(window, &winW, &winH);

        // SDL3 Mouse State (Floats)
        float winX, winY;
        SDL_GetMouseState(&winX, &winY);
        
        float scaleX = (float)winW / mask.getW();
        float scaleY = (float)winH / mask.getH();
        float imgX = winX / scaleX;
        float imgY = winY / scaleY;

        if (mask.isHit(imgX, imgY)) {
            lastValidTime = std::chrono::steady_clock::now();
            float dx = imgX - lastImgX;
            float dy = imgY - lastImgY;
            float velocity = std::sqrt(dx*dx + dy*dy);

            if (velocity > Config::kMoveThreshold) {
                lastMoveTime = std::chrono::steady_clock::now();
                float speed = Config::kIdleSpeed;
                if (velocity < Config::kLowVel) speed = Config::kMaxSpeed;
                else if (velocity > Config::kHighVel) speed = Config::kMinSpeed;
                else {
                    float t = (velocity - Config::kLowVel) / (Config::kHighVel - Config::kLowVel);
                    speed = Config::kMaxSpeed - (t * (Config::kMaxSpeed - Config::kMinSpeed));
                }
                g_state.targetSpeed = speed;
                g_state.isPlaying = true;
            } else {
                auto now = std::chrono::steady_clock::now();
                if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastMoveTime).count() > Config::kIdleTimeoutMs) {
                    g_state.isPlaying = false;
                } else {
                    g_state.targetSpeed = Config::kIdleSpeed;
                    g_state.isPlaying = true;
                }
            }
        } else {
            auto now = std::chrono::steady_clock::now();
            auto exitElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastValidTime).count();
            if (exitElapsed < Config::kExitTimeoutMs) {
                g_state.targetSpeed = Config::kIdleSpeed;
                g_state.isPlaying = true;
            } else {
                g_state.isPlaying = false;
            }
        }
        lastImgX = imgX;
        lastImgY = imgY;

        // Render
        SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
        SDL_RenderClear(renderer);
        SDL_RenderTexture(renderer, texture, NULL, NULL);
        
        statusDot.x = winW - 40.0f; statusDot.y = 10.0f;
        if (g_state.isPlaying) SDL_SetRenderDrawColor(renderer, 0, 255, 0, 255); 
        else SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255); 
        SDL_RenderFillRect(renderer, &statusDot);

        SDL_RenderPresent(renderer);
        SDL_Delay(16);
    }

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
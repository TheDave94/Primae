// App-level composition: the four-phase Schule flow + world switching.
const { useState, useEffect, useRef } = React;

// Letter A reference strokes (3 strokes: left diagonal, right diagonal, crossbar)
const LETTER_STROKES = {
  A: [
    "M 110 320 L 200 80",     // stroke 1: left diagonal
    "M 200 80  L 290 320",    // stroke 2: right diagonal
    "M 145 220 L 255 220",    // stroke 3: crossbar
  ],
  F: [
    "M 130 80  L 130 320",
    "M 130 80  L 270 80",
    "M 130 200 L 230 200",
  ],
  I: [
    "M 200 80  L 200 320",
    "M 150 80  L 250 80",
    "M 150 320 L 250 320",
  ],
  K: [
    "M 130 80  L 130 320",
    "M 130 200 L 270 80",
    "M 130 200 L 270 320",
  ],
  L: [
    "M 130 80  L 130 320",
    "M 130 320 L 270 320",
  ],
  M: [
    "M 110 320 L 110 80",
    "M 110 80  L 200 220",
    "M 200 220 L 290 80",
    "M 290 80  L 290 320",
  ],
  O: [
    "M 200 80 C 130 80 100 140 100 200 C 100 260 130 320 200 320 C 270 320 300 260 300 200 C 300 140 270 80 200 80",
  ],
};

const LETTERS = ["A", "F", "I", "K", "L", "M", "O"];

const PHASES = ["observe", "direct", "guided", "freeWrite"];
const PROMPTS = {
  observe:   "Schau mal genau hin.",
  direct:    "Tippe die Punkte der Reihe nach.",
  guided:    "Jetzt fährst du die Linien nach.",
  freeWrite: "Jetzt schreibst du den Buchstaben ganz alleine.",
};
const PRAISE_BY_STARS = ["Versuch es nochmal!", "Gut gemacht!", "Toll gemacht!", "Super!", "Sensationell!"];

function SchuleWorld() {
  const [letter, setLetter]   = useState("A");
  const [phase, setPhase]     = useState("observe");
  const [progress, setProgress] = useState({ A: 3, F: 2, I: 4, K: 1, L: 2, M: 0, O: 1 });
  const [dotIdx, setDotIdx]   = useState(0);
  const [childPath, setChildPath] = useState(null);
  const [guidePos, setGuidePos]   = useState({ x: 110, y: 320 });
  const [praise, setPraise]   = useState(null);
  const [showKP, setShowKP]   = useState(false);
  const [showCelebrate, setShowCelebrate] = useState(false);

  const ghost = LETTER_STROKES[letter] || [];

  // Animate guide dot along strokes when in observe
  useEffect(() => {
    if (phase !== "observe") return;
    let raf, t0 = performance.now();
    const totalDur = 3200;
    const tick = (t) => {
      const u = ((t - t0) % totalDur) / totalDur;       // 0..1
      const segIdx = Math.min(Math.floor(u * ghost.length), ghost.length - 1);
      const segU = (u * ghost.length) - segIdx;
      const m = /M\s*(-?[\d.]+)\s+(-?[\d.]+).*?L\s*(-?[\d.]+)\s+(-?[\d.]+)/.exec(ghost[segIdx]);
      if (m) {
        const [x1, y1, x2, y2] = [+m[1], +m[2], +m[3], +m[4]];
        setGuidePos({ x: x1 + (x2 - x1) * segU, y: y1 + (y2 - y1) * segU });
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [phase, ghost]);

  const advance = (nextPhase, options = {}) => {
    if (options.praise) {
      setPraise(options.praise);
      setTimeout(() => setPraise(null), 1600);
    }
    if (nextPhase === "kp") {
      setShowKP(true);
      setTimeout(() => { setShowKP(false); setShowCelebrate(true); }, 2200);
      return;
    }
    setPhase(nextPhase);
    setDotIdx(0);
    setChildPath(null);
  };

  const onPickLetter = (l) => {
    setLetter(l);
    setPhase("observe");
    setDotIdx(0);
    setChildPath(null);
    setShowCelebrate(false);
  };

  const completeCelebrate = () => {
    setShowCelebrate(false);
    setProgress(p => ({ ...p, [letter]: 4 }));
    setPhase("observe");
  };

  return (
    <main className="world-main world-main--schule">
      <header className="world-header">
        <div className="world-header__inner">
          <div className="world-header__title">
            <i data-lucide="book-open"/>
            <span>Schule</span>
          </div>
          <PhaseIndicator phase={phase}/>
          <div className="world-header__meta">
            <StarRow count={progress[letter] || 0}/>
            <span className="t-caption">Buchstabe&nbsp;{letter}</span>
          </div>
        </div>
      </header>

      <section className="canvas-area">
        <div className="prompt">{PROMPTS[phase]}</div>
        <TracingCanvas
          letter={letter}
          phase={phase}
          ghostStrokes={ghost}
          childPath={childPath}
          guideX={phase === "observe" ? guidePos.x : null}
          guideY={phase === "observe" ? guidePos.y : null}
          dotIndex={dotIdx}
        />

        <PraiseBand text={praise}/>

        <div className="canvas-actions">
          {phase === "observe" && (
            <StickerButton tone="schule" icon="arrow-right" onClick={() => advance("direct", { praise: "Bereit!" })}>
              Weiter
            </StickerButton>
          )}
          {phase === "direct" && (
            <StickerButton tone="schule" icon="arrow-right"
              onClick={() => {
                if (dotIdx < ghost.length - 1) setDotIdx(dotIdx + 1);
                else advance("guided", { praise: "Richtig!" });
              }}>
              {dotIdx < ghost.length - 1 ? `Punkt ${dotIdx + 2}` : "Weiter"}
            </StickerButton>
          )}
          {phase === "guided" && (
            <StickerButton tone="schule" icon="arrow-right"
              onClick={() => {
                setChildPath(ghost.join(" "));
                advance("freeWrite", { praise: "Nachspuren fertig" });
              }}>
              Nachspuren fertig
            </StickerButton>
          )}
          {phase === "freeWrite" && (
            <StickerButton tone="brand" icon="check"
              onClick={() => {
                setChildPath(ghost.join(" "));
                advance("kp", {});
              }}>
              Fertig
            </StickerButton>
          )}
        </div>
      </section>

      <LetterPicker letters={LETTERS} active={letter} progress={progress} onPick={onPickLetter}/>

      {showKP && (
        <KPOverlay ghostStrokes={ghost} childPath={childPath} onDismiss={() => { setShowKP(false); setShowCelebrate(true); }}/>
      )}
      {showCelebrate && (
        <div className="celebrate-overlay" role="dialog" aria-label="Geschafft">
          <div className="celebrate-card">
            <div className="celebrate-card__title t-display">Super!</div>
            <StarRow count={4} size={48}/>
            <div className="t-body-md" style={{ textAlign: "center", marginTop: 12 }}>
              Du hast den Buchstaben <strong>{letter}</strong> geschafft.
            </div>
            <StickerButton tone="brand" icon="arrow-right" onClick={completeCelebrate}>Weiter</StickerButton>
          </div>
        </div>
      )}
    </main>
  );
}

function WerkstattWorld() {
  return (
    <main className="world-main world-main--werkstatt">
      <header className="world-header">
        <div className="world-header__inner">
          <div className="world-header__title">
            <i data-lucide="pencil"/><span>Werkstatt</span>
          </div>
          <div className="world-header__meta"><span className="t-caption">Freies Schreiben</span></div>
        </div>
      </header>
      <section className="canvas-area">
        <div className="prompt">Schreibe was du möchtest.</div>
        <div className="canvas-stage">
          <svg className="canvas-svg" viewBox="0 0 400 400" preserveAspectRatio="xMidYMid meet">
            <line x1="40" y1="320" x2="360" y2="320" stroke="var(--info)" strokeOpacity="0.25" strokeWidth="2"/>
            <line x1="40" y1="180" x2="360" y2="180" stroke="var(--info)" strokeOpacity="0.18" strokeWidth="1.5" strokeDasharray="4 6"/>
            <text x="200" y="240" textAnchor="middle" fontFamily="Playwrite AT, cursive" fontSize="120" fill="var(--ink-stroke)">Mama</text>
          </svg>
        </div>
        <div className="canvas-actions">
          <StickerButton tone="werkstatt" icon="rotate-ccw">Neu</StickerButton>
          <StickerButton tone="brand" icon="check">Fertig</StickerButton>
        </div>
      </section>
    </main>
  );
}

function FortschritteWorld() {
  const letters = ["A","F","I","K","L","M","O"];
  const stars   = { A: 4, F: 3, I: 4, K: 2, L: 3, M: 1, O: 2 };
  return (
    <main className="world-main world-main--fortschritte">
      <header className="world-header">
        <div className="world-header__inner">
          <div className="world-header__title"><i data-lucide="star"/><span>Fortschritte</span></div>
          <div className="world-header__meta"><span className="t-caption">Heute · 3 Tage in Folge</span></div>
        </div>
      </header>
      <section className="fortschritte-grid">
        <div className="streak-card">
          <div className="t-eyebrow">Sterne gesamt</div>
          <div className="big-number">{Object.values(stars).reduce((a,b)=>a+b,0)}</div>
          <div className="t-caption">von 28 möglich</div>
        </div>
        <div className="streak-card">
          <div className="t-eyebrow">Tage in Folge</div>
          <div className="big-number">3</div>
          <div className="t-caption">aufwärts</div>
        </div>
        <div className="letter-gallery">
          {letters.map(l => (
            <div key={l} className="letter-gallery__cell">
              <div className="letter-gallery__glyph">{l}</div>
              <StarRow count={stars[l]} size={16}/>
            </div>
          ))}
        </div>
      </section>
    </main>
  );
}

function App() {
  const [world, setWorld] = useState("schule");
  const [parent, setParent] = useState(false);

  // re-render lucide icons whenever DOM changes
  useEffect(() => {
    if (window.lucide) window.lucide.createIcons();
  });

  return (
    <div className="app-shell">
      <WorldRail active={world} onChange={setWorld} onLongPressGear={() => setParent(true)}/>
      <div className="app-stage">
        {world === "schule"       && <SchuleWorld/>}
        {world === "werkstatt"    && <WerkstattWorld/>}
        {world === "fortschritte" && <FortschritteWorld/>}
      </div>
      {parent && (
        <div className="parent-overlay" role="dialog" aria-label="Eltern-Bereich">
          <div className="parent-card">
            <div className="t-eyebrow">Eltern-Bereich</div>
            <h2>Forschungs-Daten</h2>
            <p className="t-body">Schreibmotorik · A/B-Arm · Datenexport. (Parental gate — 2 s long-press unlock.)</p>
            <StickerButton tone="brand" icon="x" onClick={() => setParent(false)}>Schließen</StickerButton>
          </div>
        </div>
      )}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);

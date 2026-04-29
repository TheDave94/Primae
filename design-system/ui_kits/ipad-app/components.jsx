// Primae UI Kit — shared design tokens & primitives (vanilla JSX, no JSX modules)
// Exposes components on window so subsequent script files can reference them.

const { useState, useEffect, useRef, useMemo } = React;

// ---------- World rail (left, 64 px fixed) ----------
function WorldRail({ active, onChange, onLongPressGear }) {
  const worlds = [
    { id: "schule",       label: "Schule",       icon: "book-open",  tint: "var(--schule)",       soft: "var(--schule-soft)" },
    { id: "werkstatt",    label: "Werkstatt",    icon: "pencil",     tint: "var(--werkstatt)",    soft: "var(--werkstatt-soft)" },
    { id: "fortschritte", label: "Fortschritte", icon: "star",       tint: "var(--fortschritte)", soft: "var(--fortschritte-soft)" },
  ];
  const pressTimer = useRef();
  const startGearPress = () => {
    pressTimer.current = setTimeout(() => onLongPressGear?.(), 2000);
  };
  const cancelGearPress = () => clearTimeout(pressTimer.current);

  return (
    <aside className="world-rail" aria-label="Welten">
      <div className="world-rail__brand" aria-hidden>
        <img src="../../assets/app-glyph.svg" alt="" width="40" height="40" />
      </div>
      <div className="world-rail__items">
        {worlds.map(w => (
          <button
            key={w.id}
            className={"world-rail__btn" + (active === w.id ? " is-active" : "")}
            style={{ "--tint": w.tint, "--tint-soft": w.soft }}
            onClick={() => onChange(w.id)}
            aria-label={w.label}
            aria-current={active === w.id ? "true" : undefined}
          >
            <i data-lucide={w.icon} />
            <span className="world-rail__label">{w.label}</span>
          </button>
        ))}
      </div>
      <button
        className="world-rail__gear"
        aria-label="Eltern-Bereich (lange drücken)"
        onPointerDown={startGearPress}
        onPointerUp={cancelGearPress}
        onPointerLeave={cancelGearPress}
        onPointerCancel={cancelGearPress}
      >
        <i data-lucide="settings" />
      </button>
    </aside>
  );
}

// ---------- Phase indicator (4 dots + label) ----------
function PhaseIndicator({ phase }) {
  const phases = [
    { id: "observe",   label: "Anschauen" },
    { id: "direct",    label: "Richtung lernen" },
    { id: "guided",    label: "Nachspuren" },
    { id: "freeWrite", label: "Selbst schreiben" },
  ];
  const idx = phases.findIndex(p => p.id === phase);
  return (
    <div className="phase-ind" role="status" aria-label={`Phase: ${phases[idx]?.label}`}>
      <div className="phase-ind__dots">
        {phases.map((p, i) => (
          <span key={p.id} className={"phase-ind__dot" + (i <= idx ? " is-done" : "") + (i === idx ? " is-active" : "")} />
        ))}
      </div>
      <div className="phase-ind__label">{phases[idx]?.label}</div>
    </div>
  );
}

// ---------- Sticker button (kid-facing primary) ----------
function StickerButton({ children, onClick, tone = "brand", icon, ...rest }) {
  return (
    <button className={`btn-sticker btn-sticker--${tone}`} onClick={onClick} {...rest}>
      {icon && <i data-lucide={icon} />}
      <span>{children}</span>
    </button>
  );
}

// ---------- Letter star row (0–4) ----------
function StarRow({ count = 0, total = 4, size = 22 }) {
  return (
    <div className="star-row" aria-label={`${count} von ${total} Sternen`}>
      {Array.from({ length: total }).map((_, i) => (
        <svg key={i} width={size} height={size} viewBox="0 0 24 24" aria-hidden>
          <path
            d="M12 2 L14.6 8.6 L21.6 9.2 L16.2 13.8 L17.8 20.6 L12 17 L6.2 20.6 L7.8 13.8 L2.4 9.2 L9.4 8.6 Z"
            fill={i < count ? "var(--star)" : "var(--paper-deep)"}
            stroke="var(--ink)"
            strokeWidth="1.6"
            strokeLinejoin="round"
          />
        </svg>
      ))}
    </div>
  );
}

// ---------- Tracing canvas (renders glyph + phase-specific overlays) ----------
function TracingCanvas({ letter = "A", phase, ghostStrokes, childPath, guideX, guideY, dotIndex }) {
  const showGhost = phase === "guided";
  const showDirect = phase === "direct";
  const showGuide = phase === "observe";
  const showInk = phase === "guided" || phase === "freeWrite";

  return (
    <div className="canvas-stage" role="img" aria-label={`Buchstabe ${letter}, Phase ${phase}`}>
      <svg className="canvas-svg" viewBox="0 0 400 400" preserveAspectRatio="xMidYMid meet">
        {/* baseline + x-height ruling */}
        <line x1="40" y1="320" x2="360" y2="320" stroke="var(--info)" strokeOpacity="0.25" strokeWidth="2"/>
        <line x1="40" y1="180" x2="360" y2="180" stroke="var(--info)" strokeOpacity="0.18" strokeWidth="1.5" strokeDasharray="4 6"/>

        {/* base glyph (very faint, the "tracing surface") */}
        <text x="200" y="320" textAnchor="middle"
              fontFamily="Primae, system-ui"
              fontWeight="700" fontSize="340"
              fill="var(--paper-edge)"
              style={{ letterSpacing: "-0.04em" }}>
          {letter}
        </text>

        {/* ghost reference strokes during guided */}
        {showGhost && ghostStrokes?.map((d, i) => (
          <path key={i} d={d}
                stroke="var(--ghost)" strokeOpacity="0.4"
                strokeWidth="16" strokeLinecap="round" strokeLinejoin="round"
                fill="none"/>
        ))}

        {/* numbered start dots during direct */}
        {showDirect && ghostStrokes?.map((d, i) => {
          // pull start point from path's leading "M x y"
          const m = /M\s*(-?[\d.]+)\s+(-?[\d.]+)/.exec(d);
          if (!m) return null;
          const x = +m[1], y = +m[2];
          const isNext = i === dotIndex;
          return (
            <g key={i}>
              {isNext && <circle cx={x} cy={y} r="32" fill="var(--guide-soft)" className="pulse-halo"/>}
              <circle cx={x} cy={y} r="16" fill="var(--start-dot)"/>
              <text x={x} y={y+5} textAnchor="middle"
                    fontFamily="PrimaeText, system-ui"
                    fontWeight="700" fontSize="18"
                    fill="var(--paper)">{i+1}</text>
            </g>
          );
        })}

        {/* live ink (guided / freeWrite) */}
        {showInk && childPath && (
          <path d={childPath}
                stroke="var(--ink-stroke)" strokeWidth="14"
                strokeLinecap="round" strokeLinejoin="round" fill="none"/>
        )}

        {/* observe-phase animation guide (orange) */}
        {showGuide && guideX != null && (
          <g>
            <circle cx={guideX} cy={guideY} r="22" fill="var(--guide-soft)"/>
            <circle cx={guideX} cy={guideY} r="12" fill="var(--guide)" stroke="var(--ink)" strokeWidth="2"/>
          </g>
        )}
      </svg>
    </div>
  );
}

// ---------- Letter picker bar (bottom row) ----------
function LetterPicker({ letters, active, progress, onPick }) {
  return (
    <nav className="letter-picker" aria-label="Buchstabe wählen">
      {letters.map(l => {
        const stars = progress?.[l] ?? 0;
        return (
          <button
            key={l}
            className={"letter-cell" + (l === active ? " is-active" : "")}
            onClick={() => onPick(l)}
            aria-label={`Buchstabe ${l}, ${stars} Sterne`}
          >
            <span className="letter-cell__glyph">{l}</span>
            <StarRow count={stars} size={11} />
          </button>
        );
      })}
    </nav>
  );
}

// ---------- Praise band (fades in after a phase clears) ----------
function PraiseBand({ text }) {
  if (!text) return null;
  return <div className="praise-band">{text}</div>;
}

// ---------- KP Overlay (post-freeWrite knowledge of performance) ----------
function KPOverlay({ ghostStrokes, childPath, onDismiss }) {
  return (
    <div className="kp-overlay" onClick={onDismiss} role="dialog" aria-label="Vergleich">
      <div className="kp-overlay__inner">
        <svg viewBox="0 0 400 400" className="kp-overlay__svg">
          {ghostStrokes?.map((d, i) => (
            <path key={i} d={d} stroke="var(--ghost)" strokeOpacity="0.6" strokeWidth="14" strokeLinecap="round" fill="none"/>
          ))}
          {childPath && <path d={childPath} stroke="var(--ink-stroke)" strokeWidth="8" strokeLinecap="round" fill="none"/>}
        </svg>
        <div className="kp-overlay__caption">Tippen zum Weiter</div>
      </div>
    </div>
  );
}

// expose
Object.assign(window, {
  WorldRail, PhaseIndicator, StickerButton, StarRow, TracingCanvas, LetterPicker, PraiseBand, KPOverlay,
});

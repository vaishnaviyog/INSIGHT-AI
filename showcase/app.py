import streamlit as st

st.set_page_config(page_title="INSIGHT", page_icon="🦯", layout="wide")

GITHUB_URL = "https://github.com/vaishnaviyog/INSIGHT-AI"
APK_URL = "https://github.com/vaishnaviyog/INSIGHT-AI/releases/latest/download/app-release.apk"

st.title("🦯 INSIGHT")
st.subheader("Voice-first transit navigation for visually impaired pedestrians")

st.markdown(
    """
INSIGHT is an Android app that helps a blind or low-vision person travel somewhere using
public transit &mdash; entirely by voice. It resolves a spoken destination, plans a real
multi-leg journey (walk → bus / metro / suburban rail → walk), and guides the rider step
by step, while an on-device camera watches for obstacles along the way.
"""
)

col1, col2 = st.columns([1, 1])
with col1:
    st.link_button("⬇️ Download the APK", APK_URL, use_container_width=True)
with col2:
    st.link_button("View source on GitHub", GITHUB_URL, use_container_width=True)

st.divider()

st.header("At a glance")
m1, m2, m3, m4 = st.columns(4)
m1.metric("Automated tests", "476", "100% passing")
m2.metric("Routing success", "99.25%", "400 random routes")
m3.metric("Transit agencies", "3", "Bus · Metro · Rail")
m4.metric("Novel mechanisms", "2", "Core A & Core B")

st.divider()

st.header("The two ideas that make this different")

c1, c2 = st.columns(2)
with c1:
    st.subheader("Core A — Transit-Aware Camera Control")
    st.markdown(
        """
The hazard-detection camera doesn't run the whole time. A journey-state machine tracks
where the rider actually is &mdash; walking to the stop, boarding, riding, alighting,
walking to the destination &mdash; and automatically switches the camera **off** while
the rider is seated inside a vehicle, since there's no pedestrian hazard to detect
indoors, and back **on** the moment they get off.
"""
    )
with c2:
    st.subheader("Core B — Behaviour-Adaptive Risk Profiling")
    st.markdown(
        """
The app quietly measures, for every hazard warning it actually speaks, how long it takes
for that hazard to clear from view. Over time this builds a per-user profile &mdash;
walking speed, warning responsiveness, route familiarity &mdash; that personalises how
urgently future warnings are delivered, instead of one fixed setting for every rider.
"""
    )

st.divider()

st.header("How a journey works")
steps = [
    ("1. Speak a destination", "Voice input is cleaned up, matched against known places, and falls back to online geocoding with honest confidence scoring if nothing matches."),
    ("2. Plan the journey", "A RAPTOR-based router searches the real, merged GTFS transit feed (bus, metro, suburban rail) for the best multi-leg journey, with real street-level walking directions for the first and last mile."),
    ("3. Navigate", "Camera, GPS, compass, and voice guidance run together. An on-device YOLOv8n detector watches for hazards; a transparent, explainable risk score decides what gets spoken and how urgently."),
    ("4. Board and ride", "Core A pauses the camera the moment boarding is confirmed, and resumes it &mdash; with a clean reset &mdash; the moment the rider gets off."),
    ("5. Arrive", "On reaching the destination, the app asks where to go next, or ends the session cleanly."),
]
for title, body in steps:
    with st.expander(title):
        st.write(body)

st.divider()

st.header("Architecture")
st.caption("Generated directly from the real source code, not drawn freehand.")

st.image("docs/diagrams/figure1_architecture.png", caption="Overall system architecture — navigation pipeline and hazard-detection pipeline, with Core A/Core B integration points.")

d1, d2 = st.columns(2)
with d1:
    st.image("docs/diagrams/figure2_core_a_states.png", caption="Core A — transit-session state machine (8 states).")
with d2:
    st.image("docs/diagrams/figure3_core_b_pipeline.png", caption="Core B — behaviour-learning event pipeline.")

st.divider()

st.header("Tech stack")
st.markdown(
    "`Flutter / Dart` · `TensorFlow Lite (YOLOv8n)` · `SQLite (GTFS)` · "
    "`Hive` · `RAPTOR routing` · `OpenRouteService` · `Google Gemini`"
)

st.divider()
st.caption("INSIGHT — an assistive navigation project. See the GitHub repository for full source, tests, and documentation.")

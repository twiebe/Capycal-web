// The hot spring in the hero: one use case after another, in a loop. Each
// part of a copy is the source's (undefined), replaced (a text) or left out
// (null); site.css steams off what changes and settles in what replaces it.
const scenes = [
    {
        from: "Work",
        into: "Family",
        rule: "Busy blocker",
        source: ["Tue 10:00 - 11:00", "Board review: Q3 financials", "Room 3, agenda: cash flow, hiring plan"],
        copy: [undefined, "Busy (work)", null],
    },
    {
        from: "Personal",
        into: "Work",
        rule: "Busy + travel time",
        source: ["Wed 15:00 - 16:00", "Dentist", "Dr. Weber, Main St 12"],
        copy: ["Wed 14:30 - 16:30", "Busy", null],
    },
    {
        from: "Family",
        into: "Work",
        rule: "Skip weekends",
        source: ["Sat 10:00 - 12:00", "Football match", "Riverside pitch, bring oranges"],
        copy: [null, "Not copied: weekend", null],
    },
    {
        from: "Google (iCal feed)",
        into: "Nextcloud",
        rule: "Title and time",
        source: ["Thu 19:00 - 22:00", "Book club", "Anna's place, bring wine"],
        copy: [undefined, undefined, null],
    },
];
const kinds = ["event-time", "event-title", "event-detail"];

const spring = document.querySelector(".spring");
const motion = matchMedia("(prefers-reduced-motion: no-preference)");
let shown = 0;

function span(className, text) {
    const element = document.createElement("span");
    element.className = className;
    element.textContent = text;
    return element;
}

function render(scene) {
    const source = spring.querySelector(".calendar-source");
    source.querySelector(".calendar-name").textContent = scene.from;
    source.querySelector(".event").replaceChildren(
        ...scene.source.map((text, i) => span(kinds[i], text)),
    );
    const family = spring.querySelector(".calendar-family");
    const name = family.querySelector(".calendar-name");
    name.firstElementChild.textContent = scene.into;
    name.querySelector(".rule").textContent = scene.rule;
    family.querySelector(".event").replaceChildren(
        ...scene.source.map((text, i) => {
            const copy = scene.copy[i];
            if (copy === null) {
                const more = span("event-more", "");
                more.append(span(`${kinds[i]} private`, text));
                return more;
            }
            const swap = span("event-swap", "");
            if (copy === undefined) {
                swap.append(span(kinds[i], text));
            } else {
                swap.append(span(`${kinds[i]} private`, text), span(`${kinds[i]} event-new`, copy));
            }
            return swap;
        }),
    );
}

function play(scene) {
    render(scene);
    spring.classList.remove("leave", "play");
    // A reflow, so the animations start again
    void spring.offsetWidth;
    spring.classList.add("play");
}

// The spring keeps the size of its tallest scene, so that only the copy
// shrinks and the water and the capybara stay where they are
function reserve() {
    if (!motion.matches) {
        return;
    }
    const source = spring.querySelector(".calendar-source");
    const row = spring.querySelector(".family-row");
    source.style.minHeight = row.style.minHeight = "";
    spring.classList.add("measure");
    let sourceHeight = 0;
    let rowHeight = 0;
    for (const scene of scenes) {
        render(scene);
        sourceHeight = Math.max(sourceHeight, source.getBoundingClientRect().height);
        rowHeight = Math.max(rowHeight, row.getBoundingClientRect().height);
    }
    spring.classList.remove("measure");
    source.style.minHeight = `${Math.ceil(sourceHeight)}px`;
    row.style.minHeight = `${Math.ceil(rowHeight)}px`;
    play(scenes[shown]);
}

if (spring) {
    spring.classList.add("play");
    let width = 0;
    new ResizeObserver(() => {
        if (spring.offsetWidth !== width) {
            width = spring.offsetWidth;
            reserve();
        }
    }).observe(spring);
    document.fonts.ready.then(reserve);
    setInterval(() => {
        if (document.hidden || !motion.matches) {
            return;
        }
        spring.classList.add("leave");
        setTimeout(() => {
            shown = (shown + 1) % scenes.length;
            play(scenes[shown]);
        }, 450);
    }, 6500);
}

// A copy button on every command
const icon = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5" y="5" width="9" height="9" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M11 5V3.5A1.5 1.5 0 0 0 9.5 2h-6A1.5 1.5 0 0 0 2 3.5v6A1.5 1.5 0 0 0 3.5 11H5" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';
const done = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3 3 7-7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

for (const cmd of document.querySelectorAll(".cmd")) {
    const button = document.createElement("button");
    button.className = "copy";
    button.type = "button";
    button.setAttribute("aria-label", "Copy command");
    button.innerHTML = icon;
    button.addEventListener("click", async () => {
        await navigator.clipboard.writeText(cmd.querySelector("code").textContent);
        button.innerHTML = done;
        button.dataset.done = "";
        button.setAttribute("aria-label", "Copied");
        setTimeout(() => {
            button.innerHTML = icon;
            delete button.dataset.done;
            button.setAttribute("aria-label", "Copy command");
        }, 1600);
    });
    cmd.append(button);
}

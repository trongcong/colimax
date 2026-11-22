// Copy buttons for the install commands. The label states the result: "Copied" or "Copy failed".
document.querySelectorAll(".copy").forEach((button) => {
  const label = button.textContent;
  button.addEventListener("click", async () => {
    const code = button.parentElement.querySelector("code").textContent;
    try {
      await navigator.clipboard.writeText(code);
      button.textContent = button.dataset.done;
    } catch {
      button.textContent = button.dataset.failed;
    }
    setTimeout(() => { button.textContent = label; }, 1800);
  });
});

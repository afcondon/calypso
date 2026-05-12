// Open a hidden <input type="file"> programmatically, read the
// selected file as text, and invoke onSuccess(text) or
// onError(message). Exactly one of the two callbacks fires.
//
// Modern browsers fire a `cancel` event on the input when the user
// dismisses the dialog without picking; we treat that as a no-op
// (don't call onError so the UI doesn't show a spurious "cancelled"
// banner — the user knows they cancelled).
export const pickJsonFileImpl = (onSuccess, onError) => {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = 'application/json,.json';
  input.style.display = 'none';
  document.body.appendChild(input);

  let settled = false;
  const cleanup = () => {
    if (input.parentNode) input.parentNode.removeChild(input);
  };

  input.addEventListener('cancel', () => {
    if (settled) return;
    settled = true;
    cleanup();
    onError('cancelled');
  });

  input.addEventListener('change', () => {
    if (settled) return;
    const file = input.files && input.files[0];
    if (!file) {
      settled = true;
      cleanup();
      onError('no file selected');
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      if (settled) return;
      settled = true;
      cleanup();
      onSuccess(String(reader.result));
    };
    reader.onerror = () => {
      if (settled) return;
      settled = true;
      cleanup();
      onError('FileReader error: ' + (reader.error && reader.error.message || reader.error));
    };
    reader.readAsText(file);
  });

  input.click();
};

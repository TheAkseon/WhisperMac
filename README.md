# WhisperMac

WhisperMac is a macOS app with a Dock icon and a status window. It records while the right Command key is held, transcribes locally with `whisper.cpp`, and pastes the result into the focused app.

## Install

On a Mac with Xcode Command Line Tools, run `./install.sh`. The script builds `whisper.cpp`, downloads the multilingual medium model (about 1.5 GB), builds and signs the app, creates `WhisperMac.dmg`, installs it in `/Applications`, and creates a login agent.

Use `./install.sh --no-dmg` if you only need the installed app and cannot create a disk image in your environment.

Allow **Microphone**, **Input Monitoring**, and **Accessibility** access for WhisperMac in System Settings → Privacy & Security. The global right Command shortcut needs Input Monitoring; automatic paste needs Accessibility. Because the app is signed locally, replacing it can invalidate a saved permission. If the status window still says `needs access` while the switch is on, remove WhisperMac from that permission list, open the installed app again, enable the new entry, and click **Retry**.

Open WhisperMac from the Dock to see shortcut, paste, microphone, and model status or to change the model. Hold right Command to record, then release it to transcribe. Wait for the completion sound before starting another recording. The app keeps running when its window is closed.

## Troubleshooting

- If the window says the shortcut is unavailable, check Input Monitoring permission and click **Retry**.
- If automatic paste is blocked, check Accessibility permission for WhisperMac. The result remains in the clipboard.
- If recording does not start, check Microphone permission and ensure the selected model is marked ready in Preferences.
- The installer writes process output to `~/.whispermac/stdout.log` and `~/.whispermac/stderr.log`.
- The app writes startup, keyboard, recording, and transcription status to `~/.whispermac/debug.log` without recording the recognized text.
- Re-running `./install.sh` reuses the existing model and `whisper.cpp` checkout when valid.

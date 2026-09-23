# WhisperMac

WhisperMac is a macOS menu bar app that records while the right Command key is held, transcribes locally with `whisper.cpp`, and pastes the result into the focused app.

## Install

On a Mac with Xcode Command Line Tools, run `./install.sh`. The script builds `whisper.cpp`, downloads the multilingual medium model (about 1.5 GB), builds and signs the app, creates `WhisperMac.dmg`, installs it in `/Applications`, and starts it at login.

Use `./install.sh --no-dmg` if you only need the installed app and cannot create a disk image in your environment.

Allow **Microphone**, **Input Monitoring**, and **Accessibility** access for WhisperMac in System Settings → Privacy & Security. The global right Command shortcut needs Input Monitoring; automatic paste needs Accessibility. If you replace the app and the shortcut stops working, check those permissions and use **Retry Connection** in the menu.

Click the menu bar icon to choose and download a different model. Hold right Command to record, then release it to transcribe. Wait for the completion sound before starting another recording. Quit from the menu; the login agent will start the app again at the next login.

## Troubleshooting

- An exclamation mark in the menu bar means the keyboard event tap could not connect. Check Input Monitoring and Accessibility permission, then click **Retry Connection**.
- If the tooltip says Input Monitoring is needed, add WhisperMac in System Settings → Privacy & Security → Input Monitoring, then click **Retry Connection**.
- If recording does not start, check Microphone permission and ensure the selected model is marked ready in Preferences.
- The installer writes process output to `~/.whispermac/stdout.log` and `~/.whispermac/stderr.log`.
- The app writes startup, keyboard, recording, and transcription status to `~/.whispermac/debug.log` without recording the recognized text.
- Re-running `./install.sh` reuses the existing model and `whisper.cpp` checkout when valid.

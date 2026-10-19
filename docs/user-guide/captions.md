# Captions

WizRec turns speech into captions on your Mac. Audio never leaves the machine.

## Transcribe

1. Select an audio clip, or a clip with audio, on the timeline.
2. Choose Captions ▸ Transcribe Selected Audio. Progress shows in the window; Captions ▸
   Cancel Transcription stops it.
3. Choose Captions ▸ Add Dynamic Captions to show the words on the canvas, and
   Captions ▸ Dynamic Caption Style… to change their look.

The words are stored with the media in the project, in the same place Camtasia stores its
transcripts.

## Speech engines

| Engine | Setup | Good for |
|---|---|---|
| **Apple Speech** (default) | Allow Speech Recognition when asked. For on-device use, download the language in System Settings ▸ Keyboard ▸ Dictation | Languages Apple supports on device |
| **whisper.cpp** | Install `whisper-cli` and a model (below) | Many more languages (including Bengali), accents, noisy audio |

Choose the engine in **Captions ▸ Speech Engine** or **Settings ▸ Captions**. Settings also
picks the whisper.cpp model, shows the models folder, and takes a `whisper-cli` path.

### Setting up whisper.cpp

whisper.cpp is a free, open-source (MIT) speech recogniser. WizRec does not bundle it; it
runs the `whisper-cli` program you install.

1. Install the program, for example with Homebrew: `brew install whisper-cpp`. WizRec looks
   for `whisper-cli` in your `PATH`, `/opt/homebrew/bin` and `/usr/local/bin`, or at a path
   you set in Settings.
2. Download a ggml model (for example `ggml-small.bin` from the whisper.cpp project) into
   `~/Library/Application Support/WizRec/models/`. Create the folder if it does not exist.
   - `small` is a good balance of speed and accuracy and handles Bengali well; `medium` and
     `large-v3-turbo` are more accurate but slower and larger.
   - Models ending in `.en` (for example `ggml-base.en.bin`) understand English only.
   - With several models installed, WizRec uses the one chosen in Settings, otherwise the
     first of `small`, `large-v3-turbo`, `medium`, `large-v3`, `base`, `tiny`.
3. Language: auto-detected unless you choose one.

If the program or the model is missing, whisper.cpp shows as unavailable and Apple Speech
keeps working.

## Import and export

- Captions ▸ Import Captions… reads SRT and WebVTT files.
- Captions ▸ Export Captions as SRT… / as WebVTT… writes the project's captions.
- Captions ▸ Delete All Captions removes them (undoable).

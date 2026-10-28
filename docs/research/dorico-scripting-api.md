# Dorico scripting and automation interfaces

Research date: 2026-10-27. Local application examined read-only: `/Applications/Dorico 6.app`, version **6.2.30.6245** (both bundle version fields). No scripts were run and no project or application state was changed. Public evidence is identified by date/version; the presence of an installed file is not a runtime test. Product edition and OS can affect availability.

## Findings

Dorico exposes an **undocumented Lua macro/command interface** and a separate **WebSocket remote-control interface**. These are useful for triggering existing operations in the appropriate UI context, but neither is a documented general-purpose score object API. In September 2026 Dorico product manager Daniel Spreadbury said the remote interface targets commands and UI state, and that it cannot read a selected note's pitch, instrument, position and event IDs or reliably select an event by flow, instrument, bar and beat. [Steinberg forum, Spreadbury, 2026](https://forums.steinberg.net/t/astra-assisted-dorico-mcp-tests-successful-edits-but-questions-about-score-access/1040816)

**Important qualification:** the installed bundle also contains surprisingly extensive score-model Lua annotations and examples. They are first-party artifacts, but their existence does not establish that their bindings are initialized or usable in a normal script in 6.2.30, that they are current, or that Steinberg supports them. No runtime experiment was performed. They merit a separate investigation on a disposable project, not a claim that arbitrary score traversal works. In 2017 developer Paul Walmsley described early scripting infrastructure as limited to macros and subject to redesign; in 2025 Spreadbury said broader scripting had not yet been prioritized. [Walmsley, 2017](https://forums.steinberg.net/t/why-no-sdk/96182), [Spreadbury, 2025](https://forums.steinberg.net/t/script-lua-document/876830/13)

| Surface | Evidence and practical reach | Boundary |
| --- | --- | --- |
| Lua script and macro recorder | Script menu records commands into Lua; `DoApp.DoApp():doCommand(...)` appears in shipped examples and forum examples. Lua control flow can combine repeated commands. | Undocumented, context-dependent; no public compatibility promise or verified complete list. |
| Lua score and selection | Team says selection data cannot be retrieved in scripts; shipped score-model files describe a potential wider interface. | No proof shipped object-model calls work today; no supported selection or clipboard object API established. |
| Remote control | WebSocket API for external clients. Steinberg supplies material on request; UI/command state can be reflected. | Not a score-data API; protocol details and capabilities require the actual developer material and version testing. |
| Dialogs and UI | Commands may open dialogs. | Recording dialog interactions is unreliable; project-info example fails to apply changes. External accessibility automation is a separate approach. |
| MIDI | Official MIDI Learn maps MIDI notes/controllers to functions. | This is command input, not a score inspection API or evidence of OSC support. |
| Plug-ins | Bundle contains a development script plug-in manifest and examples. | No evidence they constitute a current public score plug-in SDK; VST instruments/effects are a different plug-in category. |

## Lua macros and command dispatch

The practical discovery workflow is to choose **Script > Start Recording Macro**, perform a small action, end recording, then inspect the generated Lua and replay it in an equivalent mode and selection. A 2022 forum account reports `usermacro.lua` in the user settings' `Script Plug-ins` folder and says another recording overwrites it, so rename a macro that should be retained. Check the actual path and behavior in the installed version rather than assuming it is identical across releases. [Steinberg forum, macro workflow](https://forums.steinberg.net/t/music-selection-of-multiple-flows/807777)

On this Mac, the existing version-specific folder is `/Users/slav/Library/Application Support/Steinberg/Dorico 6/Script Plug-ins`, and the log exists at `/Users/slav/Library/Application Support/Steinberg/Dorico 6/application.log`. In 2016 Spreadbury documented the then-unversioned `~/Library/Application Support/Steinberg/Dorico/Script plug-ins/usermacro.lua`; a later Mac installation used `Dorico 3.5`, so the versioned path must be checked locally. [Spreadbury, 2016](https://forums.steinberg.net/t/scripts/670673), [versioned path discussion](https://forums.steinberg.net/t/where-are-script-files-stored-on-a-mac/728176). To discover an action, record a small macro or inspect the log immediately after performing that action; logs can contain file paths and other project details. [Dorico.Net author](https://github.com/scott-janssens/Dorico.Net)

### Exact Lua surface observed

| Expression | Evidence and status |
| --- | --- |
| `DoApp.DoApp()` and `app:doCommand(commandString)` | Appears in installed batch example and recorded-script examples; established macro pattern, but undocumented and not runtime-tested here. |
| `DoApp.App()` and `app:createNewScore()` | Appears as the “New method” in installed `scoreCreator.lua`; runtime availability and effects unverified. |
| `app.currentScore`, `sc.flows`, `flow.allStreams`, `stream:dump()` | Used in installed `dumpScoreInfo.lua`; internal and unverified in the current script runtime. |
| `ScriptHost():createNewScore()`, `ScriptHost().currentScore` | Used in installed old example / development plug-in; no support or current-runtime claim. |
| `DoUI.DoUI():showFolderChooser(...)`, `app:open(...)`, `require 'pl.path'`, `require 'pl.dir'` | Used in installed conversion example; dependencies and current-runtime behavior unverified. |
| `stream:createNote(...)`, `stream:deleteEventsInRange(...)` | Used by installed development plug-in; potentially mutating internals, unverified and unsuitable for testing on a valuable score. |

No independent evidence for an `invoke` method or a stable API enumeration was found. File references for these examples are listed in the internal-artifacts section below.

A minimal command, adapted from Steinberg developer Walmsley's published command-string example and the installed `batchFileConversion.lua`, is:

```lua
local app = DoApp.DoApp()
app:doCommand([[Window.SwitchMode?WindowMode=kPlayMode]])
```

This requests a mode switch; it is not a playback command. The `?` and `&` strings in examples are command parameters, not evidence that arbitrary properties or URL endpoints exist. The exact behavior depends on current context. [Walmsley, 2016](https://forums.steinberg.net/t/plugins/662385?page=2); local source: `/Applications/Dorico 6.app/Contents/Resources/lua/examples/batchFileConversion.lua`.

A recorded command can be placed in a Lua loop, but a fixed iteration count does not discover how many flows, pages, or notes exist. Use the recorder to obtain the exact action and arguments for the installed version, and verify each command's effect. A reported Dorico 6 example found `NoteInput.ForceDuration?Set=false` behaved as an assignment but `NoteInput.RestMode?Set=false` still toggled: a parameter visible in a recording is not proof it behaves consistently for every command. [Forum report, 2025](https://forums.steinberg.net/t/surprises-with-lua-scripts/998242)

The jump bar and Preferences > Key Commands are useful ways to discover user-facing actions, but their names are not necessarily the exact Lua command strings. Jump-bar commands are only available in their valid context. [Dorico 5.1 manual](https://archive.steinberg.help/dorico_se/v5/en/Dorico_SE_5_Operation_Manual_en.pdf)

## What can be read or edited?

In November 2024 Spreadbury said scripts cannot retrieve information about the selection; remote control can reflect some UI properties available for the selection, but cannot inspect selected items' intrinsic musical data. In May 2025 he confirmed a request to retrieve selected notes and clipboard rhythm could not be done through the limited Lua support. The 2026 remote answer above adds explicit pitch/position and addressability limitations. These statements concern the described selection workflows; they do not prove that every shipped internal score-model method is absent. [Selection statement](https://forums.steinberg.net/t/manipulating-pitches-by-script/953481/10), [clipboard and selection](https://forums.steinberg.net/t/dorico-clipboard-lua-access/991580)

Actions such as select-all, navigation, copy, and subsequent editing can be dispatched when enabled, but dispatch does not return a note collection. Do not invent `GetSelection`, note-event identifiers, score traversal, or pitch getters from command names. For analysis requiring actual notation, an independently exported MusicXML file may be a useful separate data source, subject to export coverage and loss of Dorico-specific information; it is a snapshot and does not provide a live selection or reliable write-back identity.

## Shipped internal Lua artifacts: evidence, not a supported contract

Under `/Applications/Dorico 6.app/Contents/Resources/lua/` the installed app includes:

- `ldt/ee/steam/api/ScriptHost.lua` annotates `currentScore`, `engine`, `createNewScore`, `importMusicXML`, and `exportMusicXML`. `global.lua` lists numerous apparent score-model types. These annotation files end in `return nil`; they are not implementations of those APIs.
- `ldt/ee/steam/api/Score.lua` describes `flows`, `players`, `instruments`, `libraries`, `stepTimeInput`, `addEnsemble` and `addPlayerToEnsemble`. `Flow.lua` describes `allStreams`, `voiceStreams`, and other stream collections. `EventStream.lua` describes `events`, editing operations and other methods; `Event.lua` describes `id`, `position`, `endPosition`, and `duration`; `NoteEvent.lua` describes `pitchWithSpelling`.
- `examples/dumpScoreInfo.lua` references `DoApp.DoApp().currentScore`, iterates `sc.instruments`, `sc.flows` and `flow.allStreams`, and calls `stream:dump()`. `examples/scoreCreator.lua` includes both an explicitly labeled “Old method” using `ScriptHost():createNewScore()` and a “New method” using `DoApp.App():createNewScore()`. The inconsistent constructors and old/new labels are further reasons not to assume current validity.
- `Script Plug-ins/dev.scplugin/Info.lua` declares a development plug-in with SDK version `0.1` and menu handlers. Its companion `dev.lua` contains examples referring to `ScriptHost().currentScore`, streams, `createNote`, `deleteEventsInRange`, and score libraries. The manifest and code do not establish that this plugin is enabled, loaded, safe, or maintained in a normal installation.
- `examples/batchFileConversion.lua` refers to `require 'pl.path'`, `require 'pl.dir'`, `DoUI.DoUI():showFolderChooser`, `app:open`, and `app:doCommand`. Their availability, UI behavior and failure handling in the current user script environment are untested. The source is an example, not a documented guarantee of Penlight or a UI toolkit.

**No claim of runtime availability is made for these declarations.** A controlled follow-up could inspect non-mutating values such as `type(DoApp)`, then check whether `currentScore`, flow collections and event properties are actually exposed on a disposable copy, capturing errors and the app version. Do not run examples that create, delete, export, or change score data against valuable projects. Even a successful experiment would establish behavior only for that build, not vendor support or upgrade stability. The developer's modern statements about selection and the artifacts' apparent score access address different surfaces and cannot be reconciled solely by inspecting files.

## Console, logging and diagnosis

Forum users refer to a Script Console and use it to experiment, and shipped examples use Lua `print`; exact console availability, output behavior and menu names were not verified on 6.2.30. A remote library author reports that Dorico's `application.log` echoes internal commands triggered by user actions, while some commands cannot be executed through remote control. Treat log lines as discovery clues, not a supported command catalogue or proof of replayability. [Console discussion](https://forums.steinberg.net/t/surprises-with-lua-scripts/998242), [application log discussion](https://forums.steinberg.net/t/remote-control-api-net-library/884017/1)

For diagnosis, isolate one command, record its preconditions (edition, build, mode, open project, selection and caret), inspect resulting error/output, and compare before and after on a test project. A command may open a dialog or no-op when its context is wrong. No complete supported reflection/introspection API or stable error contract was established.

## Remote API, MIDI, OSC and GUI automation

Spreadbury states that the remote API uses WebSockets and can be used from any environment capable of driving them. He offered developer material on request via Steinberg; obtain the actual documentation for current connection, authentication/handshake, and message schema instead of guessing. Dorico 4 was reported as introducing this API. [Remote access and developer contact](https://forums.steinberg.net/t/how-can-i-gain-access-to-doricos-remote-api/828082), [Dorico 4 discussion](https://forums.steinberg.net/t/how-can-i-gain-access-to-doricos-remote-api/828082?page=2)

The [Dorico.Net implementation](https://github.com/scott-janssens/Dorico.Net) reports testing on Dorico Pro 5.1.70 for Windows. Its author describes selection and available properties as retrievable, while bar/staff context is not; this is a limited UI-facing selection representation, not the intrinsic note-data access that Spreadbury ruled out. Its [communications implementation](https://github.com/scott-janssens/Dorico.Net/blob/main/Dorico.Net/Comms/DoricoCommsContext.cs) connects via WebSocket and processes incoming responses. This is evidence about that client, not a vendor protocol contract or a test of our Mac build.

A second independent client, [Dorico Maestro](https://github.com/romanstark/dorico-maestro/blob/main/docs/protocol.md), documents and implements JSON text frames; its author reports probing Dorico Elements 6.2.30 on Windows. The reported handshake opens loopback port 4560, sends `connect` with `clientName` and `handshakeVersion`, receives a `sessiontoken` after authorization, sends `acceptsessiontoken`, then receives `kConnected`. It describes command frames with `message: command` and a command string, plus asynchronous partial status updates. Treat tokens as credentials, and confirm the current protocol and security settings in Steinberg's material. The author reports that `kOK` may mean acceptance into a UI queue rather than completion, especially while a modal dialog is open; verify the actual result. These are third-party empirical claims, not verified here or a universal protocol guarantee. The client reports 190 commands tested on its Windows setup and distinguishes others as untested or unavailable, so its catalog is useful for leads rather than proof for Pro on macOS. [Author's testing scope](https://github.com/romanstark/dorico-maestro)

The remote interface can issue normal Dorico commands and dedicated remote messages. Community reports describe `getproperties`, `getstatus`, and `getcommands`, but semantics and completeness must be checked against Steinberg's current developer material; `getcommands` was reported to reflect current availability. These reports do not establish access to note data. [Remote API discussion](https://forums.steinberg.net/t/help-understanding-dorico-websocket-api-getting-score-data-notes-dynamics-lyrics/969715)

Dorico Pro 6.2 officially supports mapping MIDI keys or buttons to menu items/functions through Preferences > Key Commands > MIDI Learn. [Steinberg manual](https://www.steinberg.help/r/dorico-pro/6.2/en/dorico/topics/user_interface/user_interface_midi_commands_assigning_t.html) This and normal MIDI input/playback are separate from WebSocket. No first-party evidence found here establishes a native OSC scripting endpoint; a bridge from OSC to MIDI, keyboard, or WebSocket would be external software and must be validated independently.

Lua can open a dialog using an appropriate command, but a recorded Project Info example did not execute the dialog's controls; reports also describe dialog operations as outside normal macro visibility and one transposition-dialog macro crash. Treat dialog behavior as a specific limitation, not a blanket proof every UI element is unreachable. [Project Info report](https://forums.steinberg.net/t/cant-find-the-lua-command-to-apply/1017403), [transposition report](https://forums.steinberg.net/t/trouble-using-clef-and-transposition-overrides-in-a-script/1025469). macOS accessibility/AppleScript or Windows automation can drive visible controls separately; focus, timing, localization and permissions introduce their own fragility. This is not the Lua score API.

## Version and support boundaries

The early developer discussions (2016–17) describe ambitions and infrastructure, not present commitments. In October 2024 Spreadbury said the team expected to retain the existing Lua engine while practical but made no long-term promise; the 2025 expanded-scripting statement gave no delivery date. The 6.2.30 bundle shows what is installed locally, not whether an upcoming build maintains the same internal symbols. [2016 developer discussion](https://forums.steinberg.net/t/plugins/662385), [2024 Lua statement](https://forums.steinberg.net/t/keyboard-shortcuts-for-playing-technique-text/943198?page=4), [2025 priorities](https://forums.steinberg.net/t/script-lua-document/876830/13)

For a production integration, prefer a documented user operation or documented remote protocol where it suffices; otherwise prototype on a copy and explicitly account for context, failures and version drift. Ask Steinberg for the Remote Control SDK and clarification of the bundled score-model examples before relying on undocumented internals.

## Application to GPhil graphic slices

The existing GPhil workflow needs frames aligned to systems, names corresponding to REAPER regions, and exported PNGs. The command surface may automate **specific operations** that the recorder or log demonstrates, such as switching modes or invoking an export; it has not been shown here to enumerate slice objects, extract their bounds or system/page identities, assign arbitrary slice names, or export each one under a controlled filename. In particular, an ordinary PDF-export command is not evidence of per-slice PNG export. Test candidate commands on a duplicate score with a small number of slices, inspecting both the resulting names and actual output files. Until a working command or supported object interface is established for each step, use Dorico's visible interface/accessibility automation for creation, naming and export, with explicit visual verification and safeguards against stale row positions. GUI automation is sensitive to focus, scrolling and timing. The bundled score-model stubs do not demonstrate a graphics-slice API.

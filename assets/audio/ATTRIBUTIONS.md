# Ambient audio — sources and licences

Every file bundled in `assets/audio/` must have a row here, with a licence that
permits **commercial redistribution inside an application**. A free app on the
Play Store still counts as commercial distribution, which rules out anything
marked non-commercial (`CC BY-NC`), and rules out the BBC Sound Effects library,
whose free licence covers personal, educational and research use only.

If a file is `CC BY`, attribution is not optional — it needs to appear somewhere
the user can reach. `CC0` and the Pixabay Content License carry no such
obligation, which is why they are the ones to prefer.

| File | Used for | Source | Author | Licence |
| --- | --- | --- | --- | --- |
| `Glass_and_Petrichor.mp3` | `Soundscape.rain` | **TODO** | **TODO** | **TODO** |

## Fill in the TODO row before shipping

The file carries no ID3 author, copyright or licence tags — I checked — so its
provenance cannot be recovered from the file itself. Whoever downloaded it needs
to record where it came from while they still remember.

If it came from Pixabay, the licence is "Pixabay Content License" and the URL of
the page is enough. If from Freesound, note the sound ID and confirm it is CC0
rather than CC BY; if it is CC BY, the author's name has to be credited in the
app.

## Technical notes

- **`Glass_and_Petrichor.mp3` has no LAME/Xing gapless metadata.** The player
  loops with `LoopMode.one`, and MP3 carries encoder padding at both ends that a
  decoder can only compensate for when that metadata is present. Expect an
  audible seam at each repeat. Re-encoding to Ogg Vorbis removes it:

  ```bash
  ffmpeg -i Glass_and_Petrichor.mp3 -c:a libvorbis -q:a 5 rain.ogg
  ```

- Keep loops 30–60 s. Longer buys nothing when repeating and the APK is already
  large. Mono is fine for rain and drones.
- Choose clips with no distinct beginning or end. A bell that rings out and stops
  sounds wrong on repeat.

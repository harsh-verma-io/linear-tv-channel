# Media

Video files live here but are **not committed** — see `.gitignore`. 

All content is openly licensed.

## Folders

| Folder | Contents | length |
|---|---|---|
| `programs/` | The actual shows — the things the schedule lists | 5–90 min |
| `idents/` | Channel identity stings between programs ("You're watching...") | 5–15 sec |
| `ads/` | Fake commercial break content | 30–90 sec |

## Where to get content

**Blender open movies** — CC-BY licensed, and the industry-standard test content:

- *Big Buck Bunny*, *Sintel*, *Tears of Steel*, *Cosmos Laundromat*
- https://studio.blender.org/films/

**Internet Archive** — public domain films and the Prelinger Archives. The vintage commercial reels
are ideal for `ads/`:

- https://archive.org/details/prelinger

## Format requirement

Every file used by the playout loop must share the same codec, resolution, frame rate, sample rate
and channel layout. Mismatched files is the one of the most common causes of the stream dying at a
program boundary.

Normalise anything downloaded with `scripts/normalise.sh` before adding it here.

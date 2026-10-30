# "Currently watching": what this client sends and expects

This describes the iOS client's side of `PUT/GET /v1/pair/presence` and of the `ignored` list in a sync push. It was written
from the notes of the Kotlin/Worker work, because `cloud/CLOUD_API.md` is not in this repo. **Check it against CLOUD_API.md §2.3
and the Worker's `PresenceRoom` before relying on it.** The client reads these answers loosely, so a small difference shows up
as "nothing appears", not as a crash.

## PUT /v1/pair/presence (a beat)

```json
{
  "profileId": "default",
  "state": "playing | paused | stopped",
  "seq": 1761850000123,
  "titleId": "tt0944947",
  "item": { "...MetaPreview as the history stores it..." },
  "key": "1:5",
  "season": 1, "episode": 5, "episodeTitle": "…", "thumb": "https://…",
  "position": 682.4, "duration": 3540.0
}
```

- `seq` grows on this device only. The server drops a beat whose `seq` is below the last one from the same device.
- `stopped` carries only `profileId`, `state`, `seq`, `titleId` and `season`/`episode`.
- Sent every 15 s while playing, at once on a pause or when the app goes to the background, and `stopped` on leaving the player.
  Beats go out one at a time, in order. Nothing is sent before the player has reached the point the file opened at.

## GET /v1/pair/presence

`{ "devices": [ … ] }` (`presence` or `items` also read). One object per device, with the beat's fields plus:

| field | use |
|---|---|
| `deviceId` | required; this device's own entry is ignored |
| `deviceName` | the badge ("PLAYING ON …"); falls back to `name`, then `platform` |
| `at` | server Unix ms of the last beat (`updatedAt` or `ts` also read); the card moves the position on from here |
| `item`, `position`, `state` | required for a card; `stopped` entries are skipped |

Entries of another `profileId` are skipped. The client polls every 20 s while Home is on screen and the app is in front, and
not at all while this device is playing.

## POST /v1/pair/sync: `ignored`

Optional. Records the server already held in a newer form, in the same shape as a pulled change (`profileId`, `kind`, `key`,
`updatedAt`, `deleted`, `data`). The client treats those writes as not saved, and adopts the server's record over its own.
Without the list the client behaves as it did before.

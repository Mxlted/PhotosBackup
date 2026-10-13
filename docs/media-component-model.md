# Backup media components

An asset is one accessible Photos-library item. A component is one durable upload
recipe. A successful current-appearance row alone does not prove that all enabled
components of that asset are backed up. Discovery and coverage use
`MediaComponentPlan`; all components use the existing exporter, hash duplicate
check, queue checkpoint, background receipt and commit path.

| Component | Ledger key prefix | PhotoKit bytes | Required when |
| --- | --- | --- | --- |
| Current appearance | `asset:` | `.photo`/`.video` when unedited; `.fullSizePhoto`/`.fullSizeVideo` when edited | Always for an included asset |
| Current Live Photo motion | `motion:` | `.pairedVideo` when unedited; `.fullSizePairedVideo` when edited | Live Photo motion is enabled |
| Google Photos edit base | `editbase:` | `.adjustmentBasePhoto` | A photo has an adjustment base; export verifies the Google editor before uploading |
| Unedited original | `original:` | `.photo` or `.video`, never a rendered resource | Originals are enabled and the asset has adjustments |
| Original Live Photo motion | `originalmotion:` | `.pairedVideo`, paired with the SHA-1 of `.photo` | Originals and Live Photo motion are enabled on an edited Live Photo |

The originals option defaults to off. Unedited assets need no second original
copy. Edited photos and edited videos add their primary unedited resource; a
video's poster image is never substituted for video bytes. RAW alternate
representations, adjustment recipes and a reversible editing history are outside
this option. Files with identical bytes use the existing remote duplicate check.
The Google edit base has a separate compatibility purpose, as documented in
[`google-photos-backed-up-rules.md`](google-photos-backed-up-rules.md).

Current and original Live Photo motion must attach to the corresponding still,
using that still's SHA-1 and the existing paired-motion protocol. The source
resources are preserved byte for byte before any requested Google Storage Saver
processing. Upload naming retains the original name when compatible, with the
rendered resource's extension when its format differs. The asset capture date is
used when available; otherwise the exporter falls back to the asset modification
date, then the staged file's date. No original/edit relationship is sent to Google:
different hashes can appear as separate remote items and can consume additional storage. The app
does not promise that Google presents the versions as one reversible edit.

An edited asset whose rendered resource is unavailable fails visibly instead of
falling back to an original and claiming the edit was backed up. Missing required
motion or original resources also fail visibly. Cloud-only resources remain
deferred in short background windows. A verified non-Google adjustment base is
an inapplicable compatibility component and needs no upload; unreadable
adjustment metadata still fails rather than pretending that check succeeded.

An edit can change a Live Photo's still without changing its motion bytes. A
remote motion duplicate is accepted only when its returned media key matches
the intended still's key. If Google reports that motion attached to another
version, the app surfaces an explicit incomplete-pair limitation and does not
upload duplicate bytes speculatively. Attaching one identical motion file to two
different still versions is not established by the existing protocol research.

Queue snapshots remain version 1. Optional `original` and existing `motion`
flags distinguish original and original-motion recipes while old records without
the flag retain their meaning. Each recipe has its own completion key and
checkpoint, including the still hash for paired motion. A partial success can
therefore survive relaunch without recording unfinished components as complete.
Enabling or disabling the preference never deletes local or remote media.
Detecting a new edit invalidates current-appearance, current-motion and edit-base
completion records while retaining immutable originals. Explicit Re-check Backups
also rechecks original components included by the current settings.

These paths use supported PhotoKit resource types. Simulator tests verify the
component matrix, resource choices, migration and durable recipes without
accessing personal media. They do not establish server behavior, Google display
grouping, quota treatment or every camera/editor resource combination; those
need explicit, authorized device testing.

Reference: [Apple's PHAssetResourceType documentation](https://developer.apple.com/documentation/photos/phassetresourcetype).

# Puschelz Addon Sync

This context describes how the WoW addon, desktop app, and backend coordinate guild data sync through SavedVariables.

## Language

**Pending Reload**:
Addon-generated sync data that exists in memory but is not yet flushed to SavedVariables on disk for the desktop app to read.
_Avoid_: Requires sync, dirty state, unsynced, pending upload

**Sync Subject**:
The in-game character whose addon-produced data is being synchronized to the backend.
_Avoid_: Uploader, executor, requester

**Sync Executor**:
The desktop-authenticated user who performs the backend upload for a sync payload.
_Avoid_: Subject, owner, requester

**Guild Sync Queue**:
A guild-visible set of pending reload work items keyed by `character-realm`, where each item represents one **Sync Subject** with sync data not yet flushed for desktop upload.
_Avoid_: Guild dirty flag, global pending state, guild reload bit

**Queue Work Item**:
An idempotent pending-reload record for one `character-realm` **Sync Subject** that receivers update in place instead of appending as duplicates.
_Avoid_: Event log entry, notification, one-shot ping

**Payload Version**:
A monotonic version number for one **Sync Subject**'s qualifying sync payload, used to dedupe repeated or stale queue broadcasts.
_Avoid_: Timestamp, retry count, message id

**Changed Scopes**:
Debug-oriented metadata that describes which sync areas contributed to the current **Payload Version** for a **Sync Subject**.
_Avoid_: Separate queue items, independent ack units, per-scope versions

**Bridge Acknowledgment**:
A desktop-written confirmation that the backend accepted a specific **Sync Subject** and **Payload Version**.
_Avoid_: Reload event, upload attempt, local flush

**Delayed Clear**:
The rule that a queue item may be cleared authoritatively only after the addon later reads a matching **Bridge Acknowledgment** from SavedVariables.
_Avoid_: Instant clear, optimistic clear, live ack

**Queue TTL**:
The maximum lifetime of a queue work item without a newer version or matching bridge acknowledgment.
_Avoid_: Permanent reminder, infinite backlog, manual cleanup window

**Broadcast Trigger**:
The subset of qualifying sync events that are allowed to publish a queue update to the guild.
_Avoid_: Any capture, every refresh, passive noise

**Sync Tooltip**:
The minimap hover tooltip that explains pending sync state separately for the local player and the guild-visible queue.
_Avoid_: Opaque indicator, combined status blob, verbose queue dump

## Relationships

- A **Pending Reload** is created when the addon updates sync data that the desktop app reads from SavedVariables.
- `/reload` or logout flush a **Pending Reload** to SavedVariables on disk so the desktop app can read it, but they do not clear the pending state by themselves.
- A **Sync Executor** uploads data on behalf of a **Sync Subject**.
- A **Pending Reload** belongs to a **Sync Subject** even when a different **Sync Executor** completes the backend sync.
- A **Guild Sync Queue** contains one pending work item per `character-realm` **Sync Subject**.
- A **Queue Work Item** is replaced or refreshed when the same `character-realm` produces newer qualifying sync data.
- A **Queue Work Item** is uniquely identified by **Sync Subject** plus **Payload Version**.
- Receivers ignore broadcasts whose **Payload Version** is older than the stored version for that **Sync Subject** and may refresh metadata when the version is equal.
- A **Payload Version** covers the whole qualifying sync payload for one **Sync Subject**, not individual scopes.
- **Changed Scopes** explain why a **Payload Version** advanced, but they do not create separate queue items.
- A **Bridge Acknowledgment** confirms backend acceptance for one **Sync Subject** and **Payload Version**.
- A **Delayed Clear** means the addon keeps showing pending work until it reloads and reads the matching **Bridge Acknowledgment**.
- A **Queue TTL** removes stale queue work after 24 hours if it was neither replaced by a newer version nor cleared by acknowledgment.
- A **Broadcast Trigger** publishes guild-visible queue work for explicit sync actions such as calendar sync, guild-order sync, and SimC sync actions.
- Passive guild-order capture creates local **Pending Reload** state but is not a **Broadcast Trigger** in v1.
- Guild bank capture is excluded from the v1 guild-visible queue.
- The **Sync Tooltip** distinguishes local **Pending Reload** state from the **Guild Sync Queue** even though both collapse into one red dot.
- Repeated guild broadcasts may occur, but receivers dedupe them into one **Queue Work Item** per `character-realm`.
- The minimap red dot is shown when the local player has a **Pending Reload** or when the **Guild Sync Queue** is non-empty.

## Example dialogue

> **Dev:** "The player scanned guild orders, so is that a **Pending Reload**?"
> **Domain expert:** "Yes. The addon has newer sync data, but the desktop app cannot read it until SavedVariables are flushed."
>
> **Dev:** "If another guild member uploads it, who owns the data?"
> **Domain expert:** "The **Sync Subject** is still the character who produced the data; the uploader is only the **Sync Executor**."
>
> **Dev:** "Is the guild signal one global bit?"
> **Domain expert:** "No. The UI can collapse it to one dot, but the **Guild Sync Queue** stays keyed by `character-realm`."
>
> **Dev:** "If the player clicks sync three times, do we get three queue entries?"
> **Domain expert:** "No. Multiple broadcasts are allowed, but receivers fold them into one **Queue Work Item** for that `character-realm`."
>
> **Dev:** "How do receivers know whether a rebroadcast is new work?"
> **Domain expert:** "They compare the incoming **Payload Version** for that **Sync Subject** against the stored one, ignore older versions, and may refresh metadata for equal versions."
>
> **Dev:** "What if calendar changed after guild orders were already synced?"
> **Domain expert:** "The subject gets one newer **Payload Version** and may resend already-synced scopes; the backend must handle that replay safely."
>
> **Dev:** "Can the red dot clear as soon as the desktop upload succeeds?"
> **Domain expert:** "Not in-session. The desktop can write a **Bridge Acknowledgment**, but the addon only applies that **Delayed Clear** after a later reload or relog."
>
> **Dev:** "What if nobody ever clears the queue item?"
> **Domain expert:** "Then the **Queue TTL** expires it after 24 hours so the guild queue does not rot into permanent noise."
>
> **Dev:** "Do passive captures announce to the whole guild?"
> **Domain expert:** "No. Passive guild-order capture only creates local **Pending Reload** state in v1; only explicit **Broadcast Triggers** publish queue work."
>
> **Dev:** "Can the hover text explain whether it's me or the guild?"
> **Domain expert:** "Yes. The **Sync Tooltip** should separate local pending work from guild queue state so the red dot stays debuggable."

## Flagged ambiguities

- "requires reload" and "data changed" were used interchangeably; resolved: use **Pending Reload** for addon data changes that the desktop app cannot see until SavedVariables are flushed.
- "uploader" and "player" were at risk of being conflated; resolved: separate **Sync Subject** from **Sync Executor**.
- "guild-wide red dot" risked implying one shared record; resolved: the dot is aggregated UI over a per-subject **Guild Sync Queue**.
- repeated broadcasts do not imply repeated pending work; resolved: the queue stores idempotent **Queue Work Items**, not an append-only event log.
- `character-realm` alone was too weak for dedupe; resolved: dedupe uses **Sync Subject** plus **Payload Version**.
- per-scope queue versions were considered and rejected for now; resolved: use one subject-level **Payload Version** plus **Changed Scopes** metadata.
- upload success and in-game clear are not the same moment; resolved: use **Bridge Acknowledgment** with **Delayed Clear** semantics.
- stale queue work needs bounded lifetime; resolved: use a fixed 24-hour **Queue TTL** in v1.
- qualifying capture and guild broadcast are not identical; resolved: use explicit **Broadcast Triggers**, keep passive guild-order capture local-only, and exclude guild bank from the v1 queue.
- one red dot risked hiding the source of pending work; resolved: use a **Sync Tooltip** that explicitly separates local and guild states.

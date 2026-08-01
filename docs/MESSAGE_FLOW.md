# Message Flow — How Data Moves Through the System

## Sending a Text Message

```
SwiftUI View: Button("Send") { client.send(to: bobId, "hello") }
                    │
                    ▼
ObscuraClient.send(to:_:)
    │
    ├─ Build ClientMessage protobuf (type: TEXT, text, timestamp)
    │
    ├─ sendToAllDevices(bobId, msg)
    │   │
    │   ├─ messenger.fetchPreKeyBundles(bobId)  ──── GET /v1/users/{bobId}
    │   │   └─ auto-populates deviceMap: deviceUuid → (userId, registrationId)
    │   │       (the registrationId slot is DIAGNOSTIC ONLY — see below)
    │   │
    │   ├─ for each device:
    │   │   ├─ messenger.processServerBundle()  ──── X3DH if no session, at (deviceUuid, 1)
    │   │   ├─ messenger.queueMessage()
    │   │   │   ├─ encrypt(deviceUuid:_:)
    │   │   │   │   └─ signalEncrypt() at ProtocolAddress(deviceUuid, 1)
    │   │   │   │      → PreKey or Whisper ciphertext
    │   │   │   ├─ wrap in EncryptedMessage protobuf
    │   │   │   └─ add to submission queue
    │   │
    │   └─ messenger.flushMessages()
    │       ├─ build SendMessageRequest protobuf (all queued submissions)
    │       └─ POST /v1/messages (protobuf, Idempotency-Key header)
    │
    ├─ messages.add(bobId, Message(..., isSent: true))  ──── persist locally
    │
    └─ sendSentSync(...)  ──── SENT_SYNC to own other devices
```

## Receiving a Message

```
Server pushes WebSocketFrame to gateway
                    │
                    ▼
GatewayConnection.onBinary
    │
    ├─ decode WebSocketFrame protobuf
    ├─ extract EnvelopeBatch.envelopes[]
    └─ for each envelope → push to waiter/queue
                    │
                    ▼
ObscuraClient.startEnvelopeLoop()
    │
    ├─ gateway.waitForRawEnvelope()
    ├─ processEnvelope(raw)
    │   │
    │   ├─ decode EncryptedMessage from envelope.message
    │   ├─ messenger.decrypt(senderUserId:senderDeviceUuid:content:messageType:)
    │   │   └─ signalDecryptPreKey()/signalDecrypt() at ProtocolAddress(senderDeviceUuid, 1)
    │   │      senderDeviceUuid comes from Envelope.sender_device_id (stamped server-side
    │   │      from the device-scoped JWT — unforgeable by the sender)
    │   ├─ decode ClientMessage from plaintext
    │   │
    │   ├─ routeMessage(clientMsg, sourceUserId, senderDeviceId, envelopeId)
    │   │   ├─ classify(payload) first — §4 decides what each arm may do
    │   │   │
    │   │   ├─ TEXT        → messages.add() ─── GRDB write ─── ValueObservation fires
    │   │   ├─ FRIEND_REQ  → friends.add()  ─── GRDB write ─── ValueObservation fires
    │   │   ├─ FRIEND_RESP → friends.updateStatus() (only if we sent the request)
    │   │   ├─ DEVICE_ANN  → verify against the PINNED recovery key (TOFU), then
    │   │   │                friends.updateDevices() with a CLAMPED timestamp
    │   │   ├─ MODEL_SYNC  → inbox.put() ── durable row ── app drains it
    │   │   ├─ SYNC_BLOB   → import friends + messages (own userId only)
    │   │   ├─ SENT_SYNC   → messages.add() (own userId only)
    │   │   ├─ SESS_RESET  → deleteAllSessions()
    │   │   └─ .unimplemented arms (FRIEND_SYNC, DEVICE_LINK_APPROVAL,
    │   │      DEVICE_RECOVERY_ANNOUNCE, SYNC_REQUEST, SETTINGS_SYNC, READ_SYNC,
    │   │      HISTORY_CHUNK) → logged, dropped, acked
    │   │
    │   ├─ emit(ReceivedMessage)  ──── to events stream + waiters
    │   └─ gateway.acknowledge([envelope.id])  ──── ACK so server deletes
    │
    └─ loop continues
                    │
                    ▼
SwiftUI View: .task { for await msgs in client.messages.observeMessages(id).values { ... } }
              ──── GRDB ValueObservation fires automatically, view re-renders
```

> **Sessions key on the device UUID, never `registrationId`**
> (`obscura-proto/SPEC.md` §0.10). `MessengerActor.deviceMap` retains
> `registrationId` only as diagnostic protocol metadata.

## Key Invariant — for kit-owned state

Friends, devices and messages are kit-owned and push to the view. **Application entries are not:**
a MODEL_SYNC becomes a row in `client.inbox`, and the app drains it (`peek` → merge → write →
`consume`). The receive path does not promote inbox rows automatically; the app
explicitly stores merged opaque entries through `client.entries`
(`obscura-proto/KIT_API.md` §3).

**For everything the kit does own: the view never asks for data. Data comes to the view.**

1. GRDB writes happen in the envelope loop (background)
2. `ValueObservation` detects the write automatically
3. `AsyncStream` emits the new state
4. SwiftUI re-renders

No polling. No manual refresh. No "pull to reload." The envelope loop IS the state machine.

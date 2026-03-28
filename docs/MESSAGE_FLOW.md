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
    │   │   └─ auto-populates deviceMap: deviceId → (userId, registrationId)
    │   │
    │   ├─ for each device:
    │   │   ├─ messenger.processServerBundle()  ──── X3DH if no session
    │   │   ├─ messenger.queueMessage()
    │   │   │   ├─ encrypt(userId, plaintext, registrationId)
    │   │   │   │   └─ SessionCipher.encrypt() → PreKey or Whisper ciphertext
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
    │   ├─ messenger.decrypt(sourceUserId, content, messageType)
    │   │   └─ SessionCipher.decryptPreKeyWhisperMessage() or .decryptWhisperMessage()
    │   ├─ decode ClientMessage from plaintext
    │   │
    │   ├─ routeMessage(clientMsg, sourceUserId)
    │   │   ├─ TEXT        → messages.add() ─── GRDB write ─── ValueObservation fires
    │   │   ├─ FRIEND_REQ  → friends.add()  ─── GRDB write ─── ValueObservation fires
    │   │   ├─ FRIEND_RESP → friends.updateStatus()
    │   │   ├─ DEVICE_ANN  → friends.updateDevices() (verify signature first)
    │   │   ├─ MODEL_SYNC  → orm.handleSync()
    │   │   ├─ SYNC_BLOB   → import friends + messages (own userId only)
    │   │   ├─ SENT_SYNC   → messages.add() (own userId only)
    │   │   ├─ FRIEND_SYNC → friends.add/remove() (own userId only)
    │   │   └─ SESS_RESET  → deleteAllSessions()
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

## Key Invariant

**The view never asks for data. Data comes to the view.**

1. GRDB writes happen in the envelope loop (background)
2. `ValueObservation` detects the write automatically
3. `AsyncStream` emits the new state
4. SwiftUI re-renders

No polling. No manual refresh. No "pull to reload." The envelope loop IS the state machine.

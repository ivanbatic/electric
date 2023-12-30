import * as Y from 'yjs'
import { ObservableV2 } from 'lib0/observable.js'
import { DbSchema, ElectricClient } from 'electric-sql/client/model'
import { uuid } from 'electric-sql/util'

interface ydocUpdateQueryRow {
  id: string
  data: string
}

const DEFAULT_STORE_TIMEOUT = 1000
const DEFAULT_CHECKPOINT_BYTES = 100_000

export interface ElectricSQLPersistanceOptions {
  /**
   * The timeout after which the data is merged and stored.
   * Default: 1000ms
   */
  storeTimeout?: number

  /**
   * The Yjs document (optional)
   */
  ydoc?: Y.Doc

  /**
   * The checkpoint size in bytes.
   * Default: 100_000 bytes
   */
  checkpointBytes?: number
}

export class ElectricSQLPersistance extends ObservableV2<{
  loaded: (electricSQLPersistance: ElectricSQLPersistance) => void
  error: (error: Error) => void
}> {
  ydoc: Y.Doc
  storeTimeout: number
  #storeTimeoutId: any
  #loaded: boolean
  #notifierUnsubscribe?: () => void
  #ydocUnsubscribe?: () => void
  #loadedUpdateIds: Set<string>
  #pendingUpdates: Uint8Array[]
  #checkpointBytes: number
  #savedBytes: number
  #webrtcSecret?: string

  constructor(
    public electricClient: ElectricClient<DbSchema<any>>,
    public ydocId: string,
    options?: ElectricSQLPersistanceOptions
  ) {
    super()
    this.ydoc = options?.ydoc || new Y.Doc()
    this.storeTimeout = options?.storeTimeout ?? DEFAULT_STORE_TIMEOUT

    this.#loaded = false
    this.#loadedUpdateIds = new Set()
    this.#pendingUpdates = []

    this.#checkpointBytes = options?.checkpointBytes ?? DEFAULT_CHECKPOINT_BYTES
    this.#savedBytes = 0

    this.#init()
  }

  async #init() {
    // Check if ydoc exists
    try {
      const rows = await this.electricClient.db.raw({
        sql: `SELECT id FROM ydoc WHERE id = ?`,
        args: [this.ydocId],
      })
      if (rows.length !== 1) {
        this.emit('error', [
          new Error(`YDoc with id ${this.ydocId} does not exist`),
        ])
        return
      }
      this.#webrtcSecret = rows[0].webrtc_secret as string | undefined
    } catch (err) {
      this.emit('error', [err as Error])
      return
    }

    this.#notifierUnsubscribe =
      this.electricClient.notifier.subscribeToDataChanges((changes) => {
        if (
          changes.changes.some(
            (change) => change.qualifiedTablename.tablename === 'ydoc_update'
          )
        ) {
          this.#loadNewUpdates()
        }
      })

    const handleYDocUpdate = (
      update: Uint8Array,
      origin: any,
      doc: Y.Doc,
      transaction: Y.Transaction
    ) => {
      this.#storeUpdates(update, origin, doc, transaction)
    }
    this.ydoc.on('updateV2', handleYDocUpdate)
    this.#ydocUnsubscribe = () => {
      this.ydoc.off('updateV2', handleYDocUpdate)
    }

    await this.#loadNewUpdates()
    this.#loaded = true
    this.emit('loaded', [this])
  }

  async #loadNewUpdates() {
    const updates = (await this.electricClient.db.raw({
      sql: `SELECT "id", "data" FROM "ydoc_update" WHERE "ydoc_id" = ? AND "id" NOT IN (${Array(
        this.#loadedUpdateIds.size
      )
        .fill('?')
        .join(' ,')}) ORDER BY id ASC`,
      args: [this.ydocId, ...Array.from(this.#loadedUpdateIds)],
    })) as unknown as ydocUpdateQueryRow[]

    updates.forEach(async (update) => {
      this.#loadedUpdateIds.add(update.id)
      const updateData = await base64ToBytes(update.data)
      this.ydoc.transact(() => {
        Y.applyUpdateV2(this.ydoc, updateData)
      }, ElectricSQLPersistance)
    })
  }

  #storeUpdates(
    update: Uint8Array,
    origin: any,
    _doc: Y.Doc,
    transaction: Y.Transaction
  ) {
    // Skip updates from remote revs, these are any that originate from this
    // persistance provider or are market as not local.
    // Essentially, we only want to store updates that originate from edits that
    // the user directly made to the document.
    if (origin == ElectricSQLPersistance || !transaction.local) return
    this.#pendingUpdates.push(update)
    if (!this.#storeTimeoutId) {
      this.#storeTimeoutId = setTimeout(() => {
        this.#storeTimeoutId = null
        this.storePendingUpdates()
      }, this.storeTimeout)
    }
  }

  async storePendingUpdates(checkpointing = false) {
    if (this.#storeTimeoutId) {
      clearTimeout(this.#storeTimeoutId)
      this.#storeTimeoutId = null
    }
    const update = Y.mergeUpdatesV2(this.#pendingUpdates)
    this.#pendingUpdates = []
    const updateId = uuid()
    this.#loadedUpdateIds.add(updateId) // Add to loaded updates so we don't load it
    const updateBase64 = await bytesToBase64(update)
    this.#savedBytes += updateBase64.length
    await this.electricClient.db.raw({
      sql: `INSERT INTO "ydoc_update" ("id", "ydoc_id", "data") VALUES (?, ?, ?)`,
      args: [updateId, this.ydocId, updateBase64],
    })
    if (!checkpointing && this.#savedBytes > this.#checkpointBytes) {
      this.#savedBytes = 0
      await this.checkpoint()
    }
  }

  /**
   * Experimental: Checkpoint the current state of the document.
   * This will merge all updates stored in the database into one update.
   * The DELETE and INSERT statements are executed in a transaction.
   * TODO:
   * - Have a way for other clients to know that the document has been checkpointed
   *   so they can reset their `loadedUpdateIds`.
   *   Maybe add a `checkpoint` column to the inserted row?
   */
  async checkpoint() {
    await this.storePendingUpdates(true)
    // Get all updates and merge them into one update
    const updates = (await this.electricClient.db.raw({
      sql: `SELECT "id", "data" FROM "ydoc_update" WHERE "ydoc_id" = ?`,
      args: [this.ydocId],
    })) as unknown as ydocUpdateQueryRow[]

    const updatesData = []
    for (const update of updates) {
      updatesData.push(await base64ToBytes(update.data))
    }

    const update = Y.mergeUpdatesV2(updatesData)
    const oldUpdateIds = updates.map((update) => update.id)
    const updateBase64 = await bytesToBase64(update)
    await this.electricClient.adapter.runInTransaction(
      {
        sql: `DELETE FROM "ydoc_update" WHERE "ydoc_id" in (${Array(
          oldUpdateIds.length
        )
          .fill('?')
          .join(', ')})`,
        args: oldUpdateIds,
      },
      {
        sql: `INSERT INTO ydoc_update ("id", "ydoc_id", "data") VALUES (?, ?, ?)`,
        args: [uuid(), this.ydocId, updateBase64],
      }
    )
  }

  destroy() {
    if (this.#storeTimeoutId) {
      clearTimeout(this.#storeTimeoutId)
    }
    if (this.#notifierUnsubscribe) {
      this.#notifierUnsubscribe()
    }
    if (this.#ydocUnsubscribe) {
      this.#ydocUnsubscribe()
    }
  }

  get loaded() {
    return this.#loaded
  }

  get webrtcSecret() {
    return this.#webrtcSecret
  }
}

export async function saveNewElectricYDoc(
  electricClient: ElectricClient<DbSchema<any>>,
  ydoc: Y.Doc
) {
  const ydocId = ydoc.guid
  const updateBase64 = await bytesToBase64(Y.encodeStateAsUpdateV2(ydoc))
  await electricClient.adapter.runInTransaction(
    {
      sql: `INSERT INTO ydoc ("id", "webrtc_secret") VALUES (?, ?);`,
      args: [ydocId, generateRandomString(64)],
    },
    {
      sql: `INSERT INTO ydoc_update ("id", "ydoc_id", "data") VALUES (?, ?, ?);`,
      args: [uuid(), ydocId, updateBase64],
    }
  )
  return ydocId
}

const generateRandomString = (length: number): string => {
  const printableAscii =
    ' !"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~'
  return Array.from({ length }, () => {
    return printableAscii.charAt(
      Math.floor(Math.random() * printableAscii.length)
    )
  }).join('')
}

// Below are temporary functions to convert between base64 and bytes
// once we have a way to store binary data in the database, we can remove these.

async function base64ToBytes(base64string: string) {
  // convert the base64 string to a Blob:
  const blob = await fetch(
    `data:application/octet-stream;base64,${base64string}`
  ).then((r) => r.blob())
  // convert the Blob to a Uint8Array:
  return new Uint8Array(await blob.arrayBuffer())
}

async function bytesToBase64(bytes: Uint8Array) {
  // From: https://stackoverflow.com/a/66046176
  // use a FileReader to generate a base64 data URI:
  const base64url: string = await new Promise((resolve) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.readAsDataURL(new Blob([bytes]))
  })
  // remove the `data:...;base64,` part from the start
  return base64url.slice(base64url.indexOf(',') + 1)
}
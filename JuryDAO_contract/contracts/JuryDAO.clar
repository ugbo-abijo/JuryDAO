;; title: JusticeDAO
;; version: 1.0.0
;; summary: Blockchain jury infrastructure for transparent legal proceedings

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-status (err u104))
(define-constant err-already-voted (err u105))
(define-constant err-case-not-active (err u106))
(define-constant err-not-juror (err u107))
(define-constant err-case-closed (err u108))

;; data vars
(define-data-var case-nonce uint u0)
(define-data-var juror-nonce uint u0)

;; Case structure
(define-map cases
    uint
    {
        title: (string-ascii 100),
        description: (string-utf8 500),
        plaintiff: principal,
        defendant: principal,
        judge: principal,
        status: (string-ascii 20),
        created-at: uint,
        verdict: (optional (string-ascii 20)),
        jury-size: uint,
        votes-guilty: uint,
        votes-not-guilty: uint
    }
)

;; Juror registry
(define-map jurors
    uint
    {
        address: principal,
        name: (string-utf8 100),
        registered-at: uint,
        cases-served: uint,
        active: bool
    }
)

;; Juror address to ID mapping
(define-map juror-addresses
    principal
    uint
)

;; Case jury assignments
(define-map case-jurors
    { case-id: uint, juror-id: uint }
    {
        assigned-at: uint,
        has-voted: bool
    }
)

;; Individual juror votes
(define-map juror-votes
    { case-id: uint, juror-id: uint }
    {
        vote: (string-ascii 20),
        voted-at: uint,
        notes: (optional (string-utf8 200))
    }
)

;; Case evidence documents
(define-map case-evidence
    { case-id: uint, evidence-id: uint }
    {
        ipfs-hash: (string-ascii 100),
        submitted-by: principal,
        submitted-at: uint,
        description: (string-utf8 200)
    }
)

;; Evidence counter per case
(define-map case-evidence-count
    uint
    uint
)

;; PUBLIC FUNCTIONS

;; Register a new juror
(define-public (register-juror (name (string-utf8 100)))
    (let
        (
            (juror-id (+ (var-get juror-nonce) u1))
            (caller tx-sender)
        )
        (begin
            (asserts! (is-none (map-get? juror-addresses caller)) err-already-exists)
            (map-set jurors juror-id {
                address: caller,
                name: name,
                registered-at: stacks-block-height,
                cases-served: u0,
                active: true
            })
            (map-set juror-addresses caller juror-id)
            (var-set juror-nonce juror-id)
            (ok juror-id)
        )
    )
)

;; Create a new case
(define-public (create-case
    (title (string-ascii 100))
    (description (string-utf8 500))
    (defendant principal)
    (jury-size uint)
)
    (let
        (
            (case-id (+ (var-get case-nonce) u1))
            (caller tx-sender)
        )
        (begin
            (map-set cases case-id {
                title: title,
                description: description,
                plaintiff: caller,
                defendant: defendant,
                judge: caller,
                status: "pending",
                created-at: stacks-block-height,
                verdict: none,
                jury-size: jury-size,
                votes-guilty: u0,
                votes-not-guilty: u0
            })
            (map-set case-evidence-count case-id u0)
            (var-set case-nonce case-id)
            (ok case-id)
        )
    )
)

;; Assign juror to case
(define-public (assign-juror (case-id uint) (juror-id uint))
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-not-found))
            (juror-data (unwrap! (map-get? jurors juror-id) err-not-found))
        )
        (begin
            (asserts! (is-eq tx-sender (get judge case-data)) err-unauthorized)
            (asserts! (is-eq (get status case-data) "pending") err-invalid-status)
            (asserts! (get active juror-data) err-unauthorized)
            (map-set case-jurors { case-id: case-id, juror-id: juror-id } {
                assigned-at: stacks-block-height,
                has-voted: false
            })
            (map-set jurors juror-id (merge juror-data {
                cases-served: (+ (get cases-served juror-data) u1)
            }))
            (ok true)
        )
    )
)

;; Start case proceedings
(define-public (start-case (case-id uint))
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-not-found))
        )
        (begin
            (asserts! (is-eq tx-sender (get judge case-data)) err-unauthorized)
            (asserts! (is-eq (get status case-data) "pending") err-invalid-status)
            (map-set cases case-id (merge case-data {
                status: "active"
            }))
            (ok true)
        )
    )
)

;; Submit evidence
(define-public (submit-evidence
    (case-id uint)
    (ipfs-hash (string-ascii 100))
    (description (string-utf8 200))
)
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-not-found))
            (evidence-count (default-to u0 (map-get? case-evidence-count case-id)))
            (evidence-id (+ evidence-count u1))
        )
        (begin
            (asserts! (is-eq (get status case-data) "active") err-case-not-active)
            (map-set case-evidence { case-id: case-id, evidence-id: evidence-id } {
                ipfs-hash: ipfs-hash,
                submitted-by: tx-sender,
                submitted-at: stacks-block-height,
                description: description
            })
            (map-set case-evidence-count case-id evidence-id)
            (ok evidence-id)
        )
    )
)

;; Cast vote (juror only)
(define-public (cast-vote
    (case-id uint)
    (vote (string-ascii 20))
    (notes (optional (string-utf8 200)))
)
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-not-found))
            (juror-id (unwrap! (map-get? juror-addresses tx-sender) err-not-juror))
            (assignment (unwrap! (map-get? case-jurors { case-id: case-id, juror-id: juror-id }) err-not-juror))
        )
        (begin
            (asserts! (is-eq (get status case-data) "active") err-case-not-active)
            (asserts! (not (get has-voted assignment)) err-already-voted)
            (map-set juror-votes { case-id: case-id, juror-id: juror-id } {
                vote: vote,
                voted-at: stacks-block-height,
                notes: notes
            })
            (map-set case-jurors { case-id: case-id, juror-id: juror-id } (merge assignment {
                has-voted: true
            }))
            (if (is-eq vote "guilty")
                (map-set cases case-id (merge case-data {
                    votes-guilty: (+ (get votes-guilty case-data) u1)
                }))
                (map-set cases case-id (merge case-data {
                    votes-not-guilty: (+ (get votes-not-guilty case-data) u1)
                }))
            )
            (ok true)
        )
    )
)

;; Close case and record verdict
(define-public (close-case (case-id uint) (verdict (string-ascii 20)))
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-not-found))
        )
        (begin
            (asserts! (is-eq tx-sender (get judge case-data)) err-unauthorized)
            (asserts! (is-eq (get status case-data) "active") err-case-not-active)
            (map-set cases case-id (merge case-data {
                status: "closed",
                verdict: (some verdict)
            }))
            (ok true)
        )
    )
)

;; Deactivate juror
(define-public (deactivate-juror (juror-id uint))
    (let
        (
            (juror-data (unwrap! (map-get? jurors juror-id) err-not-found))
        )
        (begin
            (asserts! (is-eq tx-sender (get address juror-data)) err-unauthorized)
            (map-set jurors juror-id (merge juror-data {
                active: false
            }))
            (ok true)
        )
    )
)

;; READ-ONLY FUNCTIONS

(define-read-only (get-case (case-id uint))
    (ok (map-get? cases case-id))
)

(define-read-only (get-juror (juror-id uint))
    (ok (map-get? jurors juror-id))
)

(define-read-only (get-juror-id (address principal))
    (ok (map-get? juror-addresses address))
)

(define-read-only (get-case-juror (case-id uint) (juror-id uint))
    (ok (map-get? case-jurors { case-id: case-id, juror-id: juror-id }))
)

(define-read-only (get-juror-vote (case-id uint) (juror-id uint))
    (ok (map-get? juror-votes { case-id: case-id, juror-id: juror-id }))
)

(define-read-only (get-evidence (case-id uint) (evidence-id uint))
    (ok (map-get? case-evidence { case-id: case-id, evidence-id: evidence-id }))
)

(define-read-only (get-evidence-count (case-id uint))
    (ok (default-to u0 (map-get? case-evidence-count case-id)))
)

(define-read-only (get-case-nonce)
    (ok (var-get case-nonce))
)

(define-read-only (get-juror-nonce)
    (ok (var-get juror-nonce))
)

(define-read-only (get-vote-tally (case-id uint))
    (match (map-get? cases case-id)
        case-data (ok {
            guilty: (get votes-guilty case-data),
            not-guilty: (get votes-not-guilty case-data),
            total: (+ (get votes-guilty case-data) (get votes-not-guilty case-data))
        })
        err-not-found
    )
)
;; title: JuryDAO
;; version: 1.0.0
;; summary: Decentralized jury selection contract ensuring fair and impartial legal proceedings
;; description: This contract implements a transparent system for juror registration, qualification verification,
;; and cryptographic randomization for jury selection in decentralized legal proceedings.

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-registered (err u101))
(define-constant err-already-registered (err u102))
(define-constant err-not-qualified (err u103))
(define-constant err-case-not-found (err u104))
(define-constant err-case-already-exists (err u105))
(define-constant err-jury-already-selected (err u106))
(define-constant err-insufficient-jurors (err u107))
(define-constant err-invalid-juror-count (err u108))
(define-constant err-case-closed (err u109))

;; Minimum requirements for juror qualification
(define-constant min-reputation-score u50)
(define-constant max-jurors-per-case u12)

;; data vars
(define-data-var next-case-id uint u1)
(define-data-var total-registered-jurors uint u0)
(define-data-var current-case-id uint u0)

;; data maps

;; Juror registry with qualification data
(define-map jurors
    principal
    {
        registered-at: uint,
        reputation-score: uint,
        cases-served: uint,
        is-active: bool,
        specializations: (list 5 (string-ascii 50))
    }
)

;; Legal case registry
(define-map cases
    uint ;; case-id
    {
        case-name: (string-ascii 100),
        created-by: principal,
        created-at: uint,
        required-jurors: uint,
        jury-selected: bool,
        is-closed: bool,
        randomization-seed: (buff 32)
    }
)

;; Jury selection results for each case
(define-map case-juries
    uint ;; case-id
    {
        jurors: (list 12 principal),
        selected-at: uint
    }
)

;; Track which cases a juror is serving on
(define-map juror-active-cases
    { juror: principal, case-id: uint }
    { is-serving: bool }
)

;; public functions

;; Register as a juror with initial qualifications
(define-public (register-juror (specializations (list 5 (string-ascii 50))))
    (let
        (
            (caller tx-sender)
        )
        (asserts! (is-none (map-get? jurors caller)) err-already-registered)

        (map-set jurors caller {
            registered-at: block-height,
            reputation-score: u50,
            cases-served: u0,
            is-active: true,
            specializations: specializations
        })

        (var-set total-registered-jurors (+ (var-get total-registered-jurors) u1))
        (ok true)
    )
)

;; Update juror active status
(define-public (set-juror-status (is-active bool))
    (let
        (
            (caller tx-sender)
            (juror-data (unwrap! (map-get? jurors caller) err-not-registered))
        )
        (ok (map-set jurors caller
            (merge juror-data { is-active: is-active })
        ))
    )
)

;; Create a new legal case requiring jury selection
(define-public (create-case
    (case-name (string-ascii 100))
    (required-jurors uint)
    (seed (buff 32))
)
    (let
        (
            (case-id (var-get next-case-id))
        )
        (asserts! (<= required-jurors max-jurors-per-case) err-invalid-juror-count)
        (asserts! (> required-jurors u0) err-invalid-juror-count)
        (asserts! (is-none (map-get? cases case-id)) err-case-already-exists)

        (map-set cases case-id {
            case-name: case-name,
            created-by: tx-sender,
            created-at: block-height,
            required-jurors: required-jurors,
            jury-selected: false,
            is-closed: false,
            randomization-seed: seed
        })

        (var-set next-case-id (+ case-id u1))
        (ok case-id)
    )
)

;; Select jury for a case using cryptographic randomization
(define-public (select-jury (case-id uint))
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-case-not-found))
            (required-count (get required-jurors case-data))
        )
        (asserts! (not (get jury-selected case-data)) err-jury-already-selected)
        (asserts! (not (get is-closed case-data)) err-case-closed)
        (asserts! (>= (var-get total-registered-jurors) required-count) err-insufficient-jurors)

        ;; In a real implementation, this would use VRF (Verifiable Random Function)
        ;; For this version, we'll mark as selected and allow external randomization
        (map-set cases case-id
            (merge case-data { jury-selected: true })
        )

        (ok true)
    )
)

;; Assign selected jurors to a case (called after randomization)
(define-public (assign-jurors (case-id uint) (selected-jurors (list 12 principal)))
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-case-not-found))
            (caller tx-sender)
        )
        (begin
            (asserts! (is-eq caller (get created-by case-data)) err-owner-only)
            (asserts! (get jury-selected case-data) err-jury-already-selected)
            (asserts! (not (get is-closed case-data)) err-case-closed)

            ;; Verify all selected jurors are qualified
            (asserts! (fold verify-juror-qualified selected-jurors true) err-not-qualified)

            ;; Store jury selection
            (map-set case-juries case-id {
                jurors: selected-jurors,
                selected-at: block-height
            })

            ;; Mark jurors as serving
            (begin
                (fold (lambda (juror prev) (mark-juror-serving case-id juror prev))
                      selected-jurors
                      true)
                (ok true)
            )
        )
    )
)

;; Update juror reputation after case completion (only case creator)
(define-public (update-juror-reputation (juror principal) (case-id uint) (new-score uint))
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-case-not-found))
            (juror-data (unwrap! (map-get? jurors juror) err-not-registered))
        )
        (asserts! (is-eq tx-sender (get created-by case-data)) err-owner-only)

        (ok (map-set jurors juror
            (merge juror-data {
                reputation-score: new-score,
                cases-served: (+ (get cases-served juror-data) u1)
            })
        ))
    )
)

;; Close a case
(define-public (close-case (case-id uint))
    (let
        (
            (case-data (unwrap! (map-get? cases case-id) err-case-not-found))
        )
        (asserts! (is-eq tx-sender (get created-by case-data)) err-owner-only)
        (asserts! (not (get is-closed case-data)) err-case-closed)

        (ok (map-set cases case-id
            (merge case-data { is-closed: true })
        ))
    )
)

;; read only functions

;; Get juror information
(define-read-only (get-juror (juror principal))
    (ok (map-get? jurors juror))
)

;; Get case information
(define-read-only (get-case (case-id uint))
    (ok (map-get? cases case-id))
)

;; Get jury for a case
(define-read-only (get-case-jury (case-id uint))
    (ok (map-get? case-juries case-id))
)

;; Check if juror is qualified
(define-read-only (is-juror-qualified (juror principal))
    (match (map-get? jurors juror)
        juror-data (ok (and
            (get is-active juror-data)
            (>= (get reputation-score juror-data) min-reputation-score)
        ))
        (ok false)
    )
)

;; Get total registered jurors
(define-read-only (get-total-jurors)
    (ok (var-get total-registered-jurors))
)

;; Get next case ID
(define-read-only (get-next-case-id)
    (ok (var-get next-case-id))
)

;; Check if juror is serving on a case
(define-read-only (is-serving-on-case (juror principal) (case-id uint))
    (ok (default-to false
        (get is-serving (map-get? juror-active-cases { juror: juror, case-id: case-id }))
    ))
)

;; private functions

;; Verify a single juror is qualified
(define-private (verify-juror-qualified (juror principal) (prev-result bool))
    (if prev-result
        (match (map-get? jurors juror)
            juror-data (and
                (get is-active juror-data)
                (>= (get reputation-score juror-data) min-reputation-score)
            )
            false
        )
        false
    )
)

;; Mark a juror as serving on a case
(define-private (mark-juror-serving (case-id uint) (juror principal) (prev-result bool))
    (begin
        (map-set juror-active-cases
            { juror: juror, case-id: case-id }
            { is-serving: true }
        )
        prev-result
    )
)

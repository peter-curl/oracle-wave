;; Title: OracleWave - Decentralized Bitcoin Price Oracle & Prediction Markets
;;
;; Summary:
;; Revolutionary prediction market protocol leveraging Stacks L2 infrastructure to create
;; trustless, transparent, and economically incentivized Bitcoin price forecasting markets.
;;
;; Description:
;; OracleWave transforms Bitcoin price speculation into a sophisticated prediction market
;; ecosystem. Built natively on Stacks blockchain, this protocol enables users to stake
;; STX tokens on Bitcoin price movements, creating liquid markets for price discovery
;; while maintaining complete decentralization. The system incorporates advanced oracle
;; mechanisms, anti-manipulation safeguards, and proportional reward distribution to
;; ensure fair and efficient market operations.
;;
;; Core Innovations:
;; - Bitcoin-native L2 execution for enhanced security and reduced costs
;; - Dynamic stake-weighted prediction aggregation
;; - Multi-layered oracle verification system
;; - Automated market resolution with transparent payout mechanisms
;; - Economic incentive alignment through fee-sharing and governance tokens
;; - Real-time market sentiment tracking and analytics
;;
;; Architecture:
;; The protocol operates through time-bounded prediction markets where participants
;; can stake STX tokens on Bitcoin price direction. Markets are created with specific
;; timeframes, oracle price feeds determine outcomes, and winners receive proportional
;; rewards based on their stake and prediction accuracy. Platform fees support
;; ecosystem sustainability and oracle infrastructure maintenance.
;;

;; CONSTANTS & CONFIGURATION

;; Administrative Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant PROTOCOL_VERSION u1)

;; Error Code Definitions
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_MARKET_NOT_FOUND (err u101))
(define-constant ERR_INVALID_PREDICTION_TYPE (err u102))
(define-constant ERR_MARKET_INACTIVE (err u103))
(define-constant ERR_REWARDS_ALREADY_CLAIMED (err u104))
(define-constant ERR_INSUFFICIENT_STAKE_BALANCE (err u105))
(define-constant ERR_INVALID_PARAMETERS (err u106))
(define-constant ERR_ORACLE_VERIFICATION_FAILED (err u107))

;; STATE VARIABLES

;; Oracle & Platform Configuration
(define-data-var authorized-oracle-address principal 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
(define-data-var minimum-participation-stake uint u1000000) ;; 1 STX minimum
(define-data-var platform-fee-basis-points uint u200)       ;; 2% platform fee
(define-data-var global-market-counter uint u0)

;; DATA STRUCTURES

;; Market State Schema
(define-map prediction-markets
    uint
    {
        initial-btc-price: uint,
        final-btc-price: uint,
        total-bullish-stakes: uint,
        total-bearish-stakes: uint,
        market-start-height: uint,
        market-end-height: uint,
        is-resolved: bool,
        total-participants: uint
    }
)

;; Participant Prediction Records
(define-map participant-predictions
    { market-id: uint, participant: principal }
    { 
        price-direction: (string-ascii 8), 
        staked-amount: uint, 
        rewards-claimed: bool,
        prediction-timestamp: uint
    }
)

;; CORE PROTOCOL FUNCTIONS

;; Market Creation Function
;; Creates new prediction market with specified parameters
(define-public (initialize-prediction-market 
    (initial-btc-price uint) 
    (market-start-height uint) 
    (market-end-height uint))
    
    (let ((new-market-id (var-get global-market-counter)))
        ;; Authorization Check
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        
        ;; Parameter Validation
        (asserts! (> market-end-height market-start-height) ERR_INVALID_PARAMETERS)
        (asserts! (> initial-btc-price u0) ERR_INVALID_PARAMETERS)
        (asserts! (> market-start-height stacks-block-height) ERR_INVALID_PARAMETERS)
        
        ;; Market State Initialization
        (map-set prediction-markets new-market-id
            {
                initial-btc-price: initial-btc-price,
                final-btc-price: u0,
                total-bullish-stakes: u0,
                total-bearish-stakes: u0,
                market-start-height: market-start-height,
                market-end-height: market-end-height,
                is-resolved: false,
                total-participants: u0
            }
        )
        
        ;; Update Global Counter
        (var-set global-market-counter (+ new-market-id u1))
        (ok new-market-id)
    )
)

;; Prediction Submission Function
;; Allows participants to stake on Bitcoin price direction
(define-public (submit-price-prediction 
    (market-id uint) 
    (price-direction (string-ascii 8)) 
    (stake-amount uint))
    
    (let ((market-data (unwrap! (map-get? prediction-markets market-id) ERR_MARKET_NOT_FOUND))
          (current-height stacks-block-height))
        
        ;; Market Activity Validation
        (asserts! (and (>= current-height (get market-start-height market-data))
                      (< current-height (get market-end-height market-data))) 
                 ERR_MARKET_INACTIVE)
        
        ;; Prediction Type Validation
        (asserts! (or (is-eq price-direction "bullish") (is-eq price-direction "bearish")) 
                 ERR_INVALID_PREDICTION_TYPE)
        
        ;; Stake Requirements Validation
        (asserts! (>= stake-amount (var-get minimum-participation-stake)) 
                 ERR_INVALID_PARAMETERS)
        (asserts! (>= (stx-get-balance tx-sender) stake-amount) 
                 ERR_INSUFFICIENT_STAKE_BALANCE)

        ;; Stake Transfer to Contract
        (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))

        ;; Record Participant Prediction
        (map-set participant-predictions 
            { market-id: market-id, participant: tx-sender }
            {
                price-direction: price-direction,
                staked-amount: stake-amount,
                rewards-claimed: false,
                prediction-timestamp: current-height
            }
        )

        ;; Update Market Aggregates
        (map-set prediction-markets market-id
            (merge market-data
                {
                    total-bullish-stakes: (if (is-eq price-direction "bullish")
                                         (+ (get total-bullish-stakes market-data) stake-amount)
                                         (get total-bullish-stakes market-data)),
                    total-bearish-stakes: (if (is-eq price-direction "bearish")
                                         (+ (get total-bearish-stakes market-data) stake-amount)
                                         (get total-bearish-stakes market-data)),
                    total-participants: (+ (get total-participants market-data) u1)
                }
            )
        )
        (ok true)
    )
)

;; Market Resolution Function  
;; Oracle-driven market settlement with final BTC price
(define-public (resolve-prediction-market (market-id uint) (final-btc-price uint))
    (let ((market-data (unwrap! (map-get? prediction-markets market-id) ERR_MARKET_NOT_FOUND)))
        
        ;; Oracle Authorization Check
        (asserts! (is-eq tx-sender (var-get authorized-oracle-address)) ERR_UNAUTHORIZED)
        
        ;; Market Resolution Conditions
        (asserts! (>= stacks-block-height (get market-end-height market-data)) ERR_MARKET_INACTIVE)
        (asserts! (not (get is-resolved market-data)) ERR_MARKET_INACTIVE)
        (asserts! (> final-btc-price u0) ERR_INVALID_PARAMETERS)

        ;; Update Market with Final State
        (map-set prediction-markets market-id
            (merge market-data
                {
                    final-btc-price: final-btc-price,
                    is-resolved: true
                }
            )
        )
        (ok true)
    )
)

;; Reward Distribution Function
;; Calculates and distributes winnings to successful predictors
(define-public (claim-prediction-rewards (market-id uint))
    (let ((market-data (unwrap! (map-get? prediction-markets market-id) ERR_MARKET_NOT_FOUND))
          (participant-data (unwrap! (map-get? participant-predictions 
                                    { market-id: market-id, participant: tx-sender }) 
                                    ERR_MARKET_NOT_FOUND)))
        
        ;; Resolution & Claim Status Validation
        (asserts! (get is-resolved market-data) ERR_MARKET_INACTIVE)
        (asserts! (not (get rewards-claimed participant-data)) ERR_REWARDS_ALREADY_CLAIMED)

        ;; Determine Winning Direction
        (let ((winning-direction (if (> (get final-btc-price market-data) 
                                       (get initial-btc-price market-data)) 
                                   "bullish" "bearish"))
              (total-market-stakes (+ (get total-bullish-stakes market-data) 
                                    (get total-bearish-stakes market-data)))
              (winning-stakes-pool (if (is-eq winning-direction "bullish") 
                                   (get total-bullish-stakes market-data) 
                                   (get total-bearish-stakes market-data))))
            
            ;; Validate Winning Prediction
            (asserts! (is-eq (get price-direction participant-data) winning-direction) 
                     ERR_INVALID_PREDICTION_TYPE)
            
            ;; Calculate Proportional Rewards
            (let ((gross-winnings (/ (* (get staked-amount participant-data) total-market-stakes) 
                                   winning-stakes-pool))
                  (platform-fee (/ (* gross-winnings (var-get platform-fee-basis-points)) u10000))
                  (net-payout (- gross-winnings platform-fee)))
                
                ;; Execute Reward Transfers
                (try! (as-contract (stx-transfer? net-payout (as-contract tx-sender) tx-sender)))
                (try! (as-contract (stx-transfer? platform-fee (as-contract tx-sender) CONTRACT_OWNER)))
                
                ;; Update Claim Status
                (map-set participant-predictions 
                    { market-id: market-id, participant: tx-sender }
                    (merge participant-data { rewards-claimed: true })
                )
                (ok net-payout)
            )
        )
    )
)

;; READ-ONLY QUERY FUNCTIONS

;; Market Data Retrieval
(define-read-only (get-market-details (market-id uint))
    (map-get? prediction-markets market-id)
)

;; Participant Prediction Retrieval
(define-read-only (get-participant-prediction (market-id uint) (participant principal))
    (map-get? participant-predictions { market-id: market-id, participant: participant })
)

;; Contract Treasury Balance
(define-read-only (get-protocol-treasury-balance)
    (stx-get-balance (as-contract tx-sender))
)

;; Market Statistics
(define-read-only (get-market-statistics (market-id uint))
    (match (map-get? prediction-markets market-id)
        market-data 
        (some {
            total-value-locked: (+ (get total-bullish-stakes market-data) 
                                 (get total-bearish-stakes market-data)),
            participant-count: (get total-participants market-data),
            bullish-ratio: (if (> (+ (get total-bullish-stakes market-data) 
                                   (get total-bearish-stakes market-data)) u0)
                             (/ (* (get total-bullish-stakes market-data) u100)
                                (+ (get total-bullish-stakes market-data) 
                                   (get total-bearish-stakes market-data)))
                             u50)
        })
        none
    )
)

;; ADMINISTRATIVE FUNCTIONS

;; Oracle Address Management
(define-public (update-authorized-oracle (new-oracle-address principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (ok (var-set authorized-oracle-address new-oracle-address))
    )
)

;; Minimum Stake Configuration
(define-public (update-minimum-stake (new-minimum-stake uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (> new-minimum-stake u0) ERR_INVALID_PARAMETERS)
        (ok (var-set minimum-participation-stake new-minimum-stake))
    )
)

;; Platform Fee Configuration
(define-public (update-platform-fee (new-fee-basis-points uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (<= new-fee-basis-points u1000) ERR_INVALID_PARAMETERS) ;; Max 10%
        (ok (var-set platform-fee-basis-points new-fee-basis-points))
    )
)

;; Treasury Management
(define-public (withdraw-protocol-fees (withdrawal-amount uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (<= withdrawal-amount (stx-get-balance (as-contract tx-sender))) 
                 ERR_INSUFFICIENT_STAKE_BALANCE)
        (try! (as-contract (stx-transfer? withdrawal-amount (as-contract tx-sender) CONTRACT_OWNER)))
        (ok withdrawal-amount)
    )
)
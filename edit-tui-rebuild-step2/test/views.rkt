#lang racket

;;; edit-tui/test/views.rkt —— view 资源生命周期
;;;
;;; 区分：
;;;   detach view : 从 panel 拿出来，view / engine view / document 都保留
;;;   close view  : 销毁 view，document 保留
;;;   close panel : 把 panel 内 view 全部 detach，panel 删除/保留
;;;   close doc   : 销毁 doc 的所有 view + doc
;;;
;;; 运行：racket edit-tui/test/views.rkt

(require rackunit
         racket/async-channel
         "../command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../plugins/resource/model.rkt"
         "../effects/engine.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define inbox (make-async-channel))
(define (feed eng s . evs)
  (transition-state (process-events default-env eng inbox s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (meta c)  (app:key-event (key c 'alt)))

;;; ════════════════ 构造：一个 doc + 一个 view + 一个 editor region ════════════════

(define (make-one)
  (define did (doc-id 1))
  (define vid (view-id 1))
  (define rid (region-id 1))
  (define eng (make-engine))
  (void (engine-create-doc! eng did "a.txt" "a\n"))
  (void (engine-create-view! eng vid did))
  (define ver (engine-view-doc-version (make-engine-view eng) did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "a.txt" #:saved-version ver))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (define s (state-set-focus (make-state #:workspace ws #:ids (make-id-counter 2 2 2 1)) vid))
  (values eng s did vid rid))

;;; ════════════════ C-w 四向拆分 ════════════════

(let-values ([(eng s did vid rid) (make-one)])
  (define s1 (feed eng s (ctrl 'w) (app:key-event (key 'left))))
  (check-equal? (hash-count (workspace-regions (state-workspace s1))) 2)
  (define s2 (feed eng s1 (ctrl 'w) (app:key-event (key 'up))))
  (check-equal? (hash-count (workspace-regions (state-workspace s2))) 3)
  (define s3 (feed eng s2 (ctrl 'w) (app:key-event (key 'down))))
  (check-equal? (hash-count (workspace-regions (state-workspace s3))) 4)
  (define s4 (feed eng s3 (ctrl 'w) (app:key-event (key 'right))))
  (check-equal? (hash-count (workspace-regions (state-workspace s4))) 5))

;;; ════════════════ detach / attach ════════════════

(let-values ([(eng s did vid rid) (make-one)])
  (define s1 (feed eng s (ctrl 'x)))
  (define s2 (feed eng s1 (ctrl 'd)))       ; detach-view
  (check-true (engine-view-exists? eng vid))
  (check-not-false (workspace-view (state-workspace s2) vid))
  (check-false (workspace-view-attached? (state-workspace s2) vid))
  (check-equal? (workspace-region-views (state-workspace s2) rid) '())
  (check-equal? (workspace-detached-views (state-workspace s2)) (list vid))
  (check-false (state-focus s2))

  (define s3 (feed eng s2 (ctrl 'x)))
  (define s4 (feed eng s3 (ctrl 'a)))       ; attach-detached
  (check-true (engine-view-exists? eng vid))
  (check-true (workspace-view-attached? (state-workspace s4) vid))
  (check-equal? (workspace-region-views (state-workspace s4) rid) (list vid))
  (check-equal? (state-focus s4) vid))

;;; ════════════════ close view：销毁 view，保留 doc ════════════════

(let-values ([(eng s did vid rid) (make-one)])
  (define s1 (feed eng s (ctrl 'w) (ctrl 'w)))
  (check-false (engine-view-exists? eng vid))
  (check-false (workspace-view (state-workspace s1) vid))
  (check-not-false (workspace-doc (state-workspace s1) did))
  (check-false (state-focus s1)))

;;; ════════════════ close panel：detach views，不 close ════════════════

;; 两个 editor region；M-w 删除被聚焦的那个，但 view 要保留
(let-values ([(eng s did vid rid) (make-one)])
  ;; split 出一个空 region，再 C-n 把第二个 document 装进去
  (define s1 (feed eng s (ctrl 'w) (app:key-event (key 'right))))
  (check-equal? (length (workspace-region-views (state-workspace s1) (state-focus s1))) 0)
  (define s1b (feed eng s1 (ctrl 'n)))
  (define s2 (feed eng s1b (meta 'w)))      ; 删除当前（新）region
  (define ws (state-workspace s2))
  ;; 两个 view 都还在；至少一个 detached
  (check-equal? (hash-count (workspace-views ws)) 2)
  (check-equal? (hash-count (engine-views eng)) 2)
  (check-true (for/or ([v (in-list (workspace-detached-views ws))]) #t)))

;;; ════════════════ close doc：销毁 doc + 所有 view ════════════════

(let-values ([(eng s did vid rid) (make-one)])
  (define s1 (feed eng s (ctrl 'x)))
  (define s2 (feed eng s1 (ctrl 'k)))       ; close-file
  (check-false (engine-doc-exists? eng did))
  (check-false (engine-view-exists? eng vid))
  (check-false (workspace-doc (state-workspace s2) did))
  (check-false (workspace-view (state-workspace s2) vid))
  (check-false (state-focus s2)))

;;; ════════════════ detach / close view / close panel 不触发保存确认 ════════════════

(let-values ([(eng s did vid rid) (make-one)])
  (define s1 (feed eng s (plain #\x)))      ; dirty
  (define s2 (feed eng s1 (ctrl 'x)))
  (define s3 (feed eng s2 (ctrl 'd)))       ; detach
  (check-false (state-confirm s3))
  (define s4 (feed eng s3 (ctrl 'w) (ctrl 'w)))       ; close view（focus 已 #f，no-op）
  (check-false (state-confirm s4)))


;;; ════════════════ 同一 region 多 view：cycle active / focus ════════════════

(let-values ([(eng s did vid rid) (make-one)])
  (define s1 (feed eng s (ctrl 'n)))        ; 新 document/view 挂进当前 region
  (define ws (state-workspace s1))
  (check-equal? (length (workspace-region-views ws rid)) 2)
  (check-equal? (state-focus s1) (view-id 2))
  (define s2 (feed eng s1 (ctrl 'x)))
  (define s3 (feed eng s2 (ctrl 'o)))       ; cycle
  (check-equal? (state-focus s3) vid)
  (define s4 (feed eng s3 (ctrl 'x)))
  (define s5 (feed eng s4 (ctrl 'o)))
  (check-equal? (state-focus s5) (view-id 2)))

(displayln "edit-tui views: ok")

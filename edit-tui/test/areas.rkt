#lang racket

;;; 多编辑区：M-0..M-9 切换、checkout / checkin、跨 area view 生命周期。

(require rackunit
         racket/file
         (only-in racket/list remove-duplicates)
         "../editor/host-api.rkt"
         "../app/bootstrap.rkt"
         "../host/layout.rkt"
         "../host/open.rkt"
         "../host/close.rkt"
         "../host/derived-buffer.rkt"
         "../features/placement/api.rkt"
         "../core/command/api.rkt"
         "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../host/input/dispatch.rkt"
         (only-in "../edit.rkt" render-frame))

;;; ════════════════ helpers ════════════════

(define (active-layouts state)
  (cons (state-layout state)
        (for/list ([a (in-hash-values (state-areas state))])
          (editor-area-layout a))))

(define (layout-view-ids l)
  (append*
   (for/list ([pid (in-list (layout-panel-ids l))])
     (p:panel-views (layout-panel l pid)))))

(define (all-view-ids state)
  (append* (for/list ([l (in-list (active-layouts state))])
             (layout-view-ids l))))

(define (check-unique-views! state)
  (define ids (all-view-ids state))
  (check-equal? (length ids) (length (remove-duplicates ids))
                "一个 view 不能在多个 panel / area 中重复出现"))

(define (check-area-shape! state)
  ;; 当前 area 不在 areas map 里。
  (check-false (hash-has-key? (state-areas state) (state-current-area state)))
  ;; inactive area 只能是 editor-only layout。
  (for ([a (in-hash-values (state-areas state))])
    (for ([pid (in-list (layout-panel-ids (editor-area-layout a)))])
      (check-eq? (p:panel-kind (layout-panel (editor-area-layout a) pid)) 'editor))))

(define (open-and-place! ed state path)
  (define-values (s1 _a1) (editor-open-file! ed state path))
  (define-values (s2 _a2) (editor-placement-commit ed s1))
  s2)

(define (make-temp-rkt)
  (define p (make-temporary-file "edit-area~a.rkt"))
  (display-to-file "#lang racket\n(define x 1)\n" p #:exists 'truncate)
  p)

;;; ════════════════ 初始状态 / 空 area 切换 ════════════════

(define-values (ed0 s0)
  (make-editor-app #:initial-text "hello\n" #:initial-name "a.rkt"))

(check-equal? (state-current-area s0) 1)
(check-true (area-slot? (state-area-slot s0)))
(for ([i (in-range 0 10)] #:unless (= i 1))
  (check-true (hash-has-key? (state-areas s0) i) (format "area ~a 应预建" i)))
(check-area-shape! s0)
(check-unique-views! s0)

;; chrome view 只在当前 frame。
(check-true (editor-view-in-current-area? s0 filetree-vid))
(check-true (editor-view-in-current-area? s0 status-vid))
(check-false (hash-has-key? (state-areas s0) 1))

;; area 1 -> 2 -> 1
(define s-a2 (editor-switch-area s0 2))
(check-equal? (state-current-area s-a2) 2)
(check-false (editor-focus-view-id s-a2))
(check-area-shape! s-a2)
(check-unique-views! s-a2)
(check-true (editor-view-in-current-area? s-a2 filetree-vid))
(check-false (editor-view-in-current-area? s-a2 1))

(define s-a1 (editor-switch-area s-a2 1))
(check-equal? (state-current-area s-a1) 1)
(check-equal? (editor-focus-view-id s-a1) 1)
(check-equal? (editor-view-text ed0 1) "hello\n")
(check-area-shape! s-a1)
(check-unique-views! s-a1)

;;; ════════════════ split / focus 保留 ════════════════

(define-values (s-split _a) (editor-split! ed0 s-a1 'right))
(define split-focus (layout-focus (state-layout s-split)))
(define split-panels (layout-panel-ids (state-layout s-split)))
(check-equal? (length (editor-visible-editor-panels s-split)) 2)

(define s-split-2 (editor-switch-area s-split 2))
(define s-split-back (editor-switch-area s-split-2 1))
(check-equal? (layout-focus (state-layout s-split-back)) split-focus)
(check-equal? (layout-panel-ids (state-layout s-split-back)) split-panels)
(check-unique-views! s-split-back)
(check-area-shape! s-split-back)

;;; ════════════════ M-0..M-9 键 ════════════════

(define-values (s-c3 _a2) (dispatch-key ed0 s-split-back (key #\3 'alt)))
(check-equal? (state-current-area s-c3) 3)
(check-equal? (state-pending s-c3) '())

(define-values (s-c0 _a4) (dispatch-key ed0 s-c3 (key #\0 'alt)))
(check-equal? (state-current-area s-c0) 0)
(check-area-shape! s-c0)
(check-unique-views! s-c0)

;; 切换清掉 pending / drag / select-drag。
(define s-transient
  (state-with-select-drag
   (state-with-drag s-c3 'drag)
   (select-drag 'editor 1)))
(define s-transient-switch (editor-switch-area s-transient 5))
(check-false (state-drag s-transient-switch))
(check-false (state-select-drag s-transient-switch))
(check-equal? (state-pending s-transient-switch) '())

;; 切到空 area 后也能正常渲染一帧。
(define-values (_s-rendered cache-rendered rendered-bytes)
  (render-frame ed0 s-c3 #f))
(check-true (bytes? rendered-bytes))
(check-true (positive? (bytes-length rendered-bytes)))
;; 用同一 render cache 切到另一个空 area，增量 patch 路径也要正常。
(define-values (_s-rendered2 _cache-rendered2 rendered-bytes2)
  (render-frame ed0 s-c0 cache-rendered))
(check-true (bytes? rendered-bytes2))

;;; ════════════════ 打开已打开文件：跨 area 聚焦 ════════════════

(define p (make-temp-rkt))
(dynamic-wind
 void
 (λ ()
   (define s-open (open-and-place! ed0 (editor-switch-area s-c0 1) (path->string p)))
   (define vid (editor-focus-view-id s-open))
   (check-true (number? vid))
   (define s-other (editor-switch-area s-open 4))
   (check-equal? (state-current-area s-other) 4)
   (define-values (s-focus _acts attached?)
     (editor-focus-view-if-attached! ed0 s-other vid))
   (check-true attached?)
   (check-equal? (state-current-area s-focus) 1)
   (check-equal? (editor-focus-view-id s-focus) vid)

   ;; 在别的 area 打开同一 path：自动切回 view 所在 area。
   (define s-other2 (editor-switch-area s-focus 4))
   (define-values (s-reopen _acts2) (editor-open-file! ed0 s-other2 (path->string p)))
   (check-equal? (state-current-area s-reopen) 1)
   (check-equal? (editor-focus-view-id s-reopen) vid)
   (check-true (editor-view-in-current-area? s-reopen vid))
   (check-unique-views! s-reopen)
   (check-area-shape! s-reopen)

   ;; 在别的 area 关闭 buffer：所有 area 都清掉。
   (define r (resources-find-view (state-resources s-reopen) vid))
   (check-true (resource? r))
   (define s-close-active (editor-switch-area s-reopen 4))
   (define-values (s-closed _acts3)
     (editor-close-resource! ed0 s-close-active (resource-id r)))
   (check-false (editor-view-location s-closed vid))
   (check-false (editor-view-panel-id s-closed vid))
   (check-false (resources-find-view (state-resources s-closed) vid))
   (check-unique-views! s-closed)
   (check-area-shape! s-closed))
 (λ ()
   (when (file-exists? p) (delete-file p))))

;;; ════════════════ 隐藏 chrome 后 focus fallback ════════════════

(define-values (ed1 s1b)
  (make-editor-app #:initial-text "hello\n" #:initial-name "b.rkt"))
(define s-docs-focus
  (state-with-layout
   s1b
   (layout-set-focus (state-layout s1b) 'docs)))
(define s-docs-hidden-source (editor-switch-area s-docs-focus 2))
(let ()
  ;; 在 area 2 中隐藏全局 docs，再切回 area 1；area 1 保存的 focus 'docs 应 fallback。
  (define-values (s-hidden _a) (editor-toggle-panel! ed1 s-docs-hidden-source 'docs))
  (check-false (editor-panel-visible? s-hidden 'docs))
  (define s-back (editor-switch-area s-hidden 1))
  (check-not-eq? (layout-focus (state-layout s-back)) 'docs)
  (check-true (eq? (editor-focus-panel-kind s-back) 'editor))
  (check-unique-views! s-back))

;;; ════════════════ derived buffer 在 inactive area 删除 ════════════════

(define-values (ed2 s2b)
  (make-editor-app #:initial-text "hello\n" #:initial-name "c.rkt"))
(define-values (s-d did dvid)
  (create-derived-buffer! ed2 s2b
                          #:name "mirror"
                          #:text "mirror\n"
                          #:owner 'test))
(define-values (s-d2 attached?)
  (editor-attach-view-in-new-split! s-d 1 dvid 'right))
(check-true attached?)
(check-true (editor-view-in-current-area? s-d2 dvid))
(define s-d-other (editor-switch-area s-d2 2))
(check-false (editor-view-in-current-area? s-d-other dvid))
(check-not-false (editor-view-location s-d-other dvid))
(define-values (s-d-removed _acts) (remove-derived-buffer! ed2 s-d-other did))
(check-false (editor-view-location s-d-removed dvid))
(check-unique-views! s-d-removed)
(check-area-shape! s-d-removed)

(displayln "edit-tui/test/areas.rkt: ok")

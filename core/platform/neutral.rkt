#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/restrict.rkt"
         "../doc/buffer.rkt" "../doc/batch.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt" "../viewport/project.rkt"
         "../viewport/render.rkt"
         "../unit/screen.rkt" "../unit/history.rkt"
         "state.rkt" "write.rkt" rackunit)

;;; platform/neutral.rkt —— 中性接口：状态构造 + 查询 + 解析 + 标注读 + 投影
;;;
;;; 只读投影 + 生命周期；**不含**任何写原语（在 write.rkt）与显示决策（在 reaction.rkt）。
;;; 内容变更在 program.rkt（程序面）/ command.rkt（用户面）。
;;;
;;; 引用完整性：任一 view 的 window.buffer 必是某个 buffer-entry 的 buffer。
;;; view 不存 buffer-id；要 id 就用 buffer-id-of 反查。

(provide
 ;; editor 只读投影（构造器/struct:editor 不外露）
 editor? editor-buffers editor-views editor-focus
 buffer-entry-id buffer-entry-name
 view-id view-sync
 change-report change-report? change-report-first-line change-report-last-line change-report-edits
 ;; 构造 / 生命周期
 editor-open
 editor-open-buffer
 editor-close-buffer
 editor-add-view
 editor-close-view
 editor-focus-view
 editor-focus-buffer
 ;; 查询
 editor-buffer-count
 editor-view-count
 editor-buffer-id
 editor-buffer
 editor-buffer-name
 editor-view-buffer-id
 editor-view-sync
 editor-sync
 ;; 光标 / 尺寸 / 映射（只读）
 editor-point
 editor-view-point
 editor-primary
 editor-view-primary
 editor-window
 editor-view-window
 editor-selections
 editor-view-selections
 editor-height
 editor-width
 editor-view-height
 editor-view-width
 editor-top-line
 editor-view-top-line
 editor-view-mode
 editor-view-left-col
 editor-view-top-seg
 editor-mode
 editor-left-col
 editor-top-seg
 editor-point->screen
 editor-view-point->screen
 editor-screen->point
 editor-view-screen->point
 ;; 投影
 editor->screen
 editor-view->screen
 ;; 文本 / 解析（按 buffer-id）
 editor-buffer->string
 editor-buffer->lines
 editor-buffer-line-count
 editor-buffer-line-ref
 editor-buffer-line-length
 editor-buffer-clamp-point
 editor-buffer-point->offset
 editor-buffer-offset->point
 editor-buffer-range-text
 editor-buffer-tick
 editor-buffer-content-eq?
 ;; 标注读（按 buffer-id）
 editor-restrict-at
 editor-restrict-runs
 ;; 账本查询
 editor-can-undo?
 editor-can-redo?
 editor-undo-depth
 editor-redo-depth)

;;; ---------- 构造 / 生命周期 ----------
(define (editor-open text [height 24] [width 80] #:name [name "*scratch*"])
  (define b (buffer-open text))
  (define entry (buffer-entry 0 name b (make-history)))
  (editor (list entry) (list (view 0 (window-open b height width) 'free)) 0 1 1))

;; 新增一个 buffer + 一个视图。#:focus? 控制是否把焦点交给新视图（默认**不抢**）。
;; 返回 (values editor buffer-id)。
(define (editor-open-buffer ed name text [height 24] [width 80] #:focus? [focus? #f])
  (define bid (editor-next-buffer ed))
  (define entry (buffer-entry bid name (buffer-open text) (make-history)))
  (define ed1 (struct-copy editor ed
               [buffers (append (editor-buffers ed) (list entry))]
               [next-buffer (add1 bid)]))
  (define-values (ed2 _vid) (editor-add-view ed1 bid height width #:focus? focus?))
  (values ed2 bid))

;; 新增一个视图。#:focus? 控制是否 focus 它（默认**不抢**）。返回 (values editor view-id)。
(define (editor-add-view ed bid [height 24] [width 80] [p (point 0 0)]
                         #:sync [sync 'free] #:focus? [focus? #f])
  (check-sync 'editor-add-view sync)
  (define entry (editor-buffer-entry ed bid))
  (define vid (editor-next-view ed))
  (define w (window-clamp-view
             (window-set-point (window-open (buffer-entry-buffer entry) height width) p)))
  (values (struct-copy editor ed
            [views (append (editor-views ed) (list (view vid w sync)))]
            [focus (if focus? vid (editor-focus ed))]
            [next-view (add1 vid)])
          vid))

(define (editor-close-view ed vid)
  (define vs (filter (lambda (v) (not (= (view-id v) vid))) (editor-views ed)))
  (define focus (if (= (editor-focus ed) vid)
                    (if (null? vs) #f (view-id (car vs)))
                    (editor-focus ed)))
  (struct-copy editor ed [views vs] [focus focus]))

(define (editor-close-buffer ed bid)
  (define b (buffer-entry-buffer (editor-buffer-entry ed bid)))
  (define vs (filter (lambda (v) (not (eq? b (view-buffer v)))) (editor-views ed)))
  (define bs (filter (lambda (e) (not (= (buffer-entry-id e) bid))) (editor-buffers ed)))
  (define focus
    (cond [(null? vs) #f]
          [(for/or ([v (in-list vs)]) (= (view-id v) (editor-focus ed))) (editor-focus ed)]
          [else (view-id (car vs))]))
  (struct-copy editor ed [buffers bs] [views vs] [focus focus]))

;;; ---------- 查询 ----------

(define (editor-buffer-count ed) (length (editor-buffers ed)))
(define (editor-view-count ed) (length (editor-views ed)))
(define (editor-buffer-id ed) (buffer-id-of ed (view-buffer (editor-focused-view ed))))
(define (editor-sync ed) (view-sync (editor-focused-view ed)))
(define (editor-buffer ed bid) (buffer-entry-buffer (editor-buffer-entry ed bid)))
(define (editor-buffer-name ed bid) (buffer-entry-name (editor-buffer-entry ed bid)))
(define (editor-view-buffer-id ed vid) (buffer-id-of ed (view-buffer (editor-view-ref ed vid))))
(define (editor-view-sync ed vid) (view-sync (editor-view-ref ed vid)))

;; change-report 的行区间是 edits 的投影：读时现算，不存字段。
(define (change-report-first-line r)
  (let-values ([(f _) (edits-span (change-report-edits r))]) f))
(define (change-report-last-line r)
  (let-values ([(f l) (edits-span (change-report-edits r))]) l))

(define (editor-focus-view ed vid)
  (editor-view-ref ed vid)                 ; 校验存在
  (struct-copy editor ed [focus vid]))

(define (editor-focus-buffer ed bid)
  (define b (buffer-entry-buffer (editor-buffer-entry ed bid)))
  (define v (for/first ([v (in-list (editor-views ed))] #:when (eq? b (view-buffer v))) v))
  (if v (struct-copy editor ed [focus (view-id v)]) ed))

;;; ---------- 光标 / 尺寸 / 映射（只读） ----------

(define (editor-point ed) (window-point (view-window (editor-focused-view ed))))
(define (editor-view-point ed vid) (window-point (view-window (editor-view-ref ed vid))))
;; 显式 primary：给选区值，不靠位置比较。
(define (editor-primary ed) (window-primary (view-window (editor-focused-view ed))))
(define (editor-view-primary ed vid) (window-primary (view-window (editor-view-ref ed vid))))
(define (editor-window ed) (view-window (editor-focused-view ed)))
(define (editor-view-window ed vid) (view-window (editor-view-ref ed vid)))
(define (editor-view-selections ed vid) (window-selections (view-window (editor-view-ref ed vid))))
(define (editor-selections ed) (editor-view-selections ed (editor-focus ed)))
(define (editor-height ed) (window-height (view-window (editor-focused-view ed))))
(define (editor-width ed) (window-width (view-window (editor-focused-view ed))))
(define (editor-view-height ed vid) (window-height (view-window (editor-view-ref ed vid))))
(define (editor-view-width ed vid) (window-width (view-window (editor-view-ref ed vid))))
(define (editor-top-line ed) (window-top-line (view-window (editor-focused-view ed))))
(define (editor-view-top-line ed vid) (window-top-line (view-window (editor-view-ref ed vid))))
(define (editor-view-mode ed vid) (window-mode (view-window (editor-view-ref ed vid))))
(define (editor-view-left-col ed vid) (window-left-col (view-window (editor-view-ref ed vid))))
(define (editor-view-top-seg ed vid) (window-top-seg (view-window (editor-view-ref ed vid))))
(define (editor-mode ed) (window-mode (view-window (editor-focused-view ed))))
(define (editor-left-col ed) (window-left-col (view-window (editor-focused-view ed))))
(define (editor-top-seg ed) (window-top-seg (view-window (editor-focused-view ed))))

(define (editor-point->screen ed) (window-point->screen (view-window (editor-focused-view ed))))
(define (editor-view-point->screen ed vid)
  (window-point->screen (view-window (editor-view-ref ed vid))))
(define (editor-screen->point ed row col)
  (window-screen->point (view-window (editor-focused-view ed)) row col))
(define (editor-view-screen->point ed vid row col)
  (window-screen->point (view-window (editor-view-ref ed vid)) row col))

;;; ---------- 投影 ----------

(define (editor-view->screen ed vid [face-provider no-face-provider])
  (window->screen (view-window (editor-view-ref ed vid)) face-provider))
(define (editor->screen ed [face-provider no-face-provider])
  (editor-view->screen ed (editor-focus ed) face-provider))

;;; ---------- 文本 / 解析 / 标注读（按 buffer-id） ----------

(define (editor-buffer->string ed bid) (buffer->string (editor-buffer ed bid)))
(define (editor-buffer->lines ed bid) (buffer->lines (editor-buffer ed bid)))
(define (editor-buffer-line-count ed bid) (buffer-line-count (editor-buffer ed bid)))
(define (editor-buffer-line-ref ed bid i) (buffer-line-ref (editor-buffer ed bid) i))
(define (editor-buffer-line-length ed bid i) (buffer-line-length (editor-buffer ed bid) i))
(define (editor-buffer-clamp-point ed bid p) (buffer-clamp-point (editor-buffer ed bid) p))
(define (editor-buffer-point->offset ed bid p) (buffer-point->offset (editor-buffer ed bid) p))
(define (editor-buffer-offset->point ed bid off) (buffer-offset->point (editor-buffer ed bid) off))
(define (editor-buffer-range-text ed bid s e) (buffer-range-text (editor-buffer ed bid) s e))
(define (editor-buffer-tick ed bid) (buffer-tick (editor-buffer ed bid)))
(define (editor-buffer-content-eq? ed b1 b2)
  (buffer-content-eq? (editor-buffer ed b1) (editor-buffer ed b2)))
(define (editor-restrict-at ed bid p) (buffer-restrict-at (editor-buffer ed bid) p))
(define (editor-restrict-runs ed bid line) (buffer-restrict-runs (editor-buffer ed bid) line))

;;; ---------- 账本查询 ----------

(define (editor-can-undo? ed bid)
  (history-can-undo? (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-can-redo? ed bid)
  (history-can-redo? (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-undo-depth ed bid)
  (history-undo-depth (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-redo-depth ed bid)
  (history-redo-depth (buffer-entry-history (editor-buffer-entry ed bid))))

;;; ---------- 测试：中性面 ----------

(module+ test
  (define e0 (editor-open "hello\nworld" 2 10))
  (check-equal? (editor-buffer->string e0 0) "hello\nworld")
  (check-equal? (editor-buffer-line-length e0 0 0) 5)
  (check-equal? (editor-buffer-clamp-point e0 0 (point 9 9)) (point 1 5))
  (check-equal? (editor-buffer-point->offset e0 0 (point 1 0)) 6)
  (check-equal? (editor-point e0) (point 0 0))
  (check-true (screen? (editor->screen e0)))
  ;; 显式 view 只读：mode / left-col / top-seg（不经过焦点）
  (check-equal? (editor-view-mode e0 0) 'clip)
  (check-equal? (editor-view-left-col e0 0) 0)
  (check-equal? (editor-view-top-seg e0 0) 0)
  ;; 焦点 view 读糖（与 editor-view-* 镜像）
  (check-equal? (editor-mode e0) 'clip)
  (check-equal? (editor-left-col e0) 0)
  (check-equal? (editor-top-seg e0) 0)
  (check-false (editor-can-undo? e0 0))

  ;; 变化计数：读口（并发/合并的版本戳）
  (check-equal? (editor-buffer-tick e0 0) 0)
  (check-true (editor-buffer-content-eq? e0 0 0))
  (define-values (et _dt) (editor-apply-edit e0 0 (edit-desc (point 0 0) (point 0 0) "X")))
  (check-equal? (editor-buffer-tick et 0) 1)

  ;; 约束读：区间的 restrict 段
  (define pr (editor-update-buffer e0 0
                (lambda (b) (buffer-put-restrict b (point 0 0) (point 0 5) (restrict #t)))))
  (check-equal? (editor-restrict-runs pr 0 0) (list (list 0 5 (restrict #t))))

  ;; #:focus? #f：后台开 buffer 不抢焦点
  (define-values (e1 _bid) (editor-open-buffer e0 "b" "BBB" #:focus? #f))
  (check-equal? (editor-buffer-id e1) 0)
  (check-equal? (editor-buffer-count e1) 2)

  ;; 结构变换：set-view-buffer 换属主、不改文本、不动焦点
  (define n1 (editor-set-view-buffer e1 0 1))
  (check-equal? (editor-view-buffer-id n1 0) 1)
  (check-equal? (editor-buffer->string n1 1) "BBB")

  (displayln "editor.rkt: all tests passed"))

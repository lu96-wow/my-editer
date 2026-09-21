#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt"
         "../doc/buffer.rkt" "../doc/batch.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt" "../viewport/project.rkt"
         "../unit/screen.rkt" "../unit/history.rkt"
         "state.rkt")

;;; platform/neutral.rkt —— 中性接口：状态构造 + 查询 + 解析 + 属性读 + 投影
;;;
;;; 只读投影 + 生命周期；**不含**任何写原语（在 write.rkt）与显示决策（在 reaction.rkt）。
;;; 内容变更在 program.rkt（程序面）/ command.rkt（用户面）。
;;;
;;; 引用完整性：任一 view 的 window.buffer 必是某个 buffer-entry 的 buffer。
;;; 要 buffer-id 就用 buffer-id-of 反查。

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
 editor-view-buffer
 editor-view-sync
 editor-sync
 ;; 光标 / 尺寸 / 映射（只读）
 editor-point
 editor-view-point
 editor-primary
 editor-view-primary
 editor-primary-index
 editor-view-primary-index
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
 ;; 投影（face-provider : editor bid line → runs）
 no-face-provider
 attrs-provider
 editor->screen
 editor-view->screen
 ;; 点算子（editor 级）
 editor-point-left editor-view-point-left
 editor-point-right editor-view-point-right
 editor-point-home editor-view-point-home
 editor-point-end editor-view-point-end
 editor-point-up editor-view-point-up
 editor-point-down editor-view-point-down
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
 ;; 属性读（按 buffer-id）
 editor-attr-at
 editor-attr-runs
 editor-attr-key-runs
 ;; 账本查询
 editor-can-undo?
 editor-can-redo?
 editor-undo-depth
 editor-redo-depth)

;;; ---------- 构造 / 生命周期 ----------
(define (editor-open text [height 24] [width 80] #:name [name "*scratch*"])
  (define b (buffer-open text))
  (define entry (buffer-entry 0 name b (history-empty)))
  (editor (list entry) (list (view 0 (window-open b height width) 'free)) 0 1 1))

;; 新增一个 buffer + 一个视图。#:name 命名（默认 *scratch*）；#:focus? 控制是否把焦点交给新视图
;; （默认**不抢**）。返回 (values editor buffer-id)。
(define (editor-open-buffer ed text [height 24] [width 80]
                            #:name [name "*scratch*"] #:focus? [focus? #f])
  (define bid (editor-next-buffer ed))
  (define entry (buffer-entry bid name (buffer-open text) (history-empty)))
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

;; 焦点 view 所属 buffer 的 id（focus 糖的默认 bid）。
(define (focused-bid ed) (editor-view-buffer-id ed (editor-focus ed)))

(define (editor-buffer-count ed) (length (editor-buffers ed)))
(define (editor-view-count ed) (length (editor-views ed)))
(define (editor-buffer-id ed) (focused-bid ed))
;; bid 省略时用焦点 view 的 buffer（focus 糖）。
(define (editor-buffer ed [bid (focused-bid ed)]) (buffer-entry-buffer (editor-buffer-entry ed bid)))
(define (editor-buffer-name ed [bid (focused-bid ed)]) (buffer-entry-name (editor-buffer-entry ed bid)))
(define (editor-view-buffer-id ed vid) (buffer-id-of ed (view-buffer (editor-view-ref ed vid))))
(define (editor-view-buffer ed vid) (view-buffer (editor-view-ref ed vid)))
(define (editor-view-sync ed vid) (view-sync (editor-view-ref ed vid)))
(define (editor-sync ed) (editor-view-sync ed (editor-focus ed)))

;; change-report 的行区间是 edits 的投影，读时现算。
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
;; 每个操作只有一份实现（editor-view-* 按 vid）；editor-* 是焦点糖，委托给它。

(define (editor-point ed) (editor-view-point ed (editor-focus ed)))
(define (editor-view-point ed vid) (window-point (view-window (editor-view-ref ed vid))))
;; 显式 primary：给选区值，不靠位置比较。
(define (editor-primary ed) (editor-view-primary ed (editor-focus ed)))
(define (editor-view-primary ed vid) (window-primary (view-window (editor-view-ref ed vid))))
(define (editor-primary-index ed) (editor-view-primary-index ed (editor-focus ed)))
(define (editor-view-primary-index ed vid) (window-primary-index (view-window (editor-view-ref ed vid))))
(define (editor-window ed) (editor-view-window ed (editor-focus ed)))
(define (editor-view-window ed vid) (view-window (editor-view-ref ed vid)))
(define (editor-selections ed) (editor-view-selections ed (editor-focus ed)))
(define (editor-view-selections ed vid) (window-selections (view-window (editor-view-ref ed vid))))
(define (editor-height ed) (editor-view-height ed (editor-focus ed)))
(define (editor-width ed) (editor-view-width ed (editor-focus ed)))
(define (editor-view-height ed vid) (window-height (view-window (editor-view-ref ed vid))))
(define (editor-view-width ed vid) (window-width (view-window (editor-view-ref ed vid))))
(define (editor-top-line ed) (editor-view-top-line ed (editor-focus ed)))
(define (editor-view-top-line ed vid) (window-top-line (view-window (editor-view-ref ed vid))))
(define (editor-mode ed) (editor-view-mode ed (editor-focus ed)))
(define (editor-view-mode ed vid) (window-mode (view-window (editor-view-ref ed vid))))
(define (editor-left-col ed) (editor-view-left-col ed (editor-focus ed)))
(define (editor-view-left-col ed vid) (window-left-col (view-window (editor-view-ref ed vid))))
(define (editor-top-seg ed) (editor-view-top-seg ed (editor-focus ed)))
(define (editor-view-top-seg ed vid) (window-top-seg (view-window (editor-view-ref ed vid))))

(define (editor-point->screen ed) (editor-view-point->screen ed (editor-focus ed)))
(define (editor-view-point->screen ed vid)
  (window-point->screen (view-window (editor-view-ref ed vid))))
(define (editor-screen->point ed row col)
  (editor-view-screen->point ed (editor-focus ed) row col))
(define (editor-view-screen->point ed vid row col)
  (window-screen->point (view-window (editor-view-ref ed vid)) row col))

;;; ---------- 投影 ----------
;;; face-provider : editor bid line → (listof (list start end face))；投影时按需调用。
;;; 内部适配成 viewport 的 buffer 级 provider，应用不见 buffer。

(define (no-face-provider _ed _bid _line) '())

;; 把属性 buffer 的某个 key 物化成 face-provider。
(define (attrs-provider key)
  (lambda (ed bid line) (editor-attr-key-runs ed bid line key)))

(define (editor-view->screen ed vid [face-provider no-face-provider])
  (define bid (editor-view-buffer-id ed vid))
  (window->screen (view-window (editor-view-ref ed vid))
                  (lambda (_b line) (face-provider ed bid line))))
(define (editor->screen ed [face-provider no-face-provider])
  (editor-view->screen ed (editor-focus ed) face-provider))

;;; ---------- 点算子（editor 级：位置只认 point，buffer 由 bid/vid 解析） ----------
;;; 应用写导航/扩选时不再需要拿 buffer / window。

(define (editor-point-left ed p) (point-left (editor-buffer ed (focused-bid ed)) p))
(define (editor-view-point-left ed vid p) (point-left (editor-view-buffer ed vid) p))
(define (editor-point-right ed p) (point-right (editor-buffer ed (focused-bid ed)) p))
(define (editor-view-point-right ed vid p) (point-right (editor-view-buffer ed vid) p))
(define (editor-point-home ed p) (point-home p))
(define (editor-view-point-home ed vid p) (point-home p))
(define (editor-point-end ed p) (point-end (editor-buffer ed (focused-bid ed)) p))
(define (editor-view-point-end ed vid p) (point-end (editor-view-buffer ed vid) p))
(define (editor-point-up ed p) (point-up (editor-window ed) p))
(define (editor-view-point-up ed vid p) (point-up (editor-view-window ed vid) p))
(define (editor-point-down ed p) (point-down (editor-window ed) p))
(define (editor-view-point-down ed vid p) (point-down (editor-view-window ed vid) p))

;;; ---------- 文本 / 解析 / 属性读（按 buffer-id） ----------
;;; bid 缺省 = 焦点 buffer；只有「ed 后只有一个参数」的读口能安全缺省
;;; （带 payload 时，位置缺省会与 payload 抢参数，故必须显式给 bid）。

(define (editor-buffer->string ed [bid (focused-bid ed)]) (buffer->string (editor-buffer ed bid)))
(define (editor-buffer->lines ed [bid (focused-bid ed)]) (buffer->lines (editor-buffer ed bid)))
(define (editor-buffer-line-count ed [bid (focused-bid ed)]) (buffer-line-count (editor-buffer ed bid)))
(define (editor-buffer-line-ref ed bid i) (buffer-line-ref (editor-buffer ed bid) i))
(define (editor-buffer-line-length ed bid i) (buffer-line-length (editor-buffer ed bid) i))
(define (editor-buffer-clamp-point ed bid p) (buffer-clamp-point (editor-buffer ed bid) p))
(define (editor-buffer-point->offset ed bid p) (buffer-point->offset (editor-buffer ed bid) p))
(define (editor-buffer-offset->point ed bid off) (buffer-offset->point (editor-buffer ed bid) off))
(define (editor-buffer-range-text ed bid s e) (buffer-range-text (editor-buffer ed bid) s e))
(define (editor-buffer-tick ed [bid (focused-bid ed)]) (buffer-tick (editor-buffer ed bid)))
(define (editor-buffer-content-eq? ed b1 b2)
  (buffer-content-eq? (editor-buffer ed b1) (editor-buffer ed b2)))
(define (editor-attr-at ed bid p) (buffer-attr-at (editor-buffer ed bid) p))
(define (editor-attr-runs ed bid line) (buffer-attr-runs (editor-buffer ed bid) line))
(define (editor-attr-key-runs ed bid line key)
  (buffer-attr-key-runs (editor-buffer ed bid) line key))

;;; ---------- 账本查询 ----------

(define (editor-can-undo? ed [bid (focused-bid ed)])
  (history-can-undo? (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-can-redo? ed [bid (focused-bid ed)])
  (history-can-redo? (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-undo-depth ed [bid (focused-bid ed)])
  (history-undo-depth (buffer-entry-history (editor-buffer-entry ed bid))))
(define (editor-redo-depth ed [bid (focused-bid ed)])
  (history-redo-depth (buffer-entry-history (editor-buffer-entry ed bid))))

;;; ---------- 测试：中性面 ----------

(module+ test
  (require rackunit "write.rkt")
  (define e0 (editor-open "hello\nworld" 2 10))
  ;; 文本 / 位置解析 / 投影
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

  ;; 属性读：任意 key 的段；read-only 是保留 key
  (define pr (editor-update-buffer e0 0
                (lambda (b) (buffer-put-attr b (point 0 0) (point 0 5) read-only-key #t))))
  (check-equal? (editor-attr-runs pr 0 0) (list (list 0 5 (hash read-only-key #t))))
  (check-equal? (editor-attr-key-runs pr 0 0 read-only-key) (list (list 0 5 #t)))

  ;; #:focus? #f：后台开 buffer 不抢焦点
  (define-values (e1 _bid) (editor-open-buffer e0 "BBB" #:name "b" #:focus? #f))
  (check-equal? (editor-buffer-id e1) 0)
  (check-equal? (editor-buffer-count e1) 2)

  ;; 结构变换：set-view-buffer 换属主、不改文本、不动焦点
  (define n1 (editor-set-view-buffer e1 0 1))
  (check-equal? (editor-view-buffer-id n1 0) 1)
  (check-equal? (editor-buffer->string n1 1) "BBB")

  ;; focus 糖默认 bid：editor-buffer / 账本查询省略 bid 时看焦点 buffer
  (check-eq? (editor-buffer e0) (editor-buffer e0 0))
  (check-equal? (editor-buffer->string e0) (editor-buffer->string e0 0))
  (check-equal? (editor-buffer-line-count e0) (editor-buffer-line-count e0 0))
  (check-false (editor-can-undo? e0))
  ;; 按 view 直取 buffer（省一次 buffer-id 往返）
  (check-eq? (editor-view-buffer e0 0) (editor-buffer e0 0))
  ;; primary 下标读口（focus / 指定 view）
  (check-equal? (editor-primary-index e0) 0)
  (check-equal? (editor-view-primary-index e0 0) 0)

  ;; 点算子（editor 级：不碰 buffer/window）
  (check-equal? (editor-point-right e0 (point 0 0)) (point 0 1))
  (check-equal? (editor-point-left e0 (point 1 0)) (point 0 5))
  (check-equal? (editor-point-end e0 (point 0 0)) (point 0 5))
  (check-equal? (editor-point-up e0 (point 1 0)) (point 0 0))
  (check-equal? (editor-point-down e0 (point 0 0)) (point 1 0))

  ;; 属性 buffer 物化成 provider：editor->screen 直接读，无需 buffer
  (define pa (editor-update-buffer e0 0
                (lambda (b) (buffer-put-attr b (point 0 0) (point 0 5) 'face (hash 'face 'keyword)))))
  (check-equal? (vector-ref (screen-row-runs (editor->screen pa (attrs-provider 'face))) 0)
                (list (run 0 "hello" (hash 'face 'keyword))))
  (check-equal? (vector-ref (screen-row-runs (editor->screen pa)) 0)
                (list (run 0 "hello" (hash))))

  (displayln "editor.rkt: all tests passed"))

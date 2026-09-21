#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/attr.rkt" "../atom/change.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt" "../viewport/project.rkt"
         "../unit/screen.rkt" "../unit/history.rkt"
         "state.rkt")

;;; platform/neutral.rkt —— 中性接口：状态构造 + 查询 + 解析 + 属性读 + 投影
;;;
;;; 只读投影 + 生命周期；**不含**任何写原语（在 write.rkt）与显示决策（在 reaction.rkt）。
;;; 内容变更在 program.rkt（程序面）/ command.rkt（用户面）。
;;;
;;; 引用完整性：任一 view 的 window.document 必是某个 document-entry 的 document。
;;; 要 buffer-id 就用 buffer-id-of 反查。

(provide
 ;; editor 只读投影（构造器/struct:editor 不外露）
 editor? editor-documents editor-views editor-focus
 document-entry-id document-entry-name
 view-id view-sync
 change-report change-report? change-report-first-line change-report-last-line change-report-texts change-report-attrs
 ;; 构造 / 生命周期
 editor-open
 editor-open-document
 editor-close-document
 editor-add-view
 editor-close-view
 editor-focus-view
 editor-focus-document
 ;; 查询
 editor-document-count
 editor-view-count
 editor-document-id
 editor-buffer
 editor-document
 editor-attrs
 editor-document-name
 editor-view-document-id
 editor-view-buffer
 editor-view-document
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
 editor-selection-set
 editor-view-selection-set
 editor-selection-set-name
 editor-view-selection-set-name
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
 ;; 投影（face-provider : editor did line → runs）
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
 editor-text-tick
 editor-attr-tick
 editor-buffer-content-eq?
 editor-attrs-eq?
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
  (define d (document-open text))
  (define entry (document-entry 0 name d (history-empty)))
  (editor (list entry) (list (view 0 (window-open d height width) 'free)) 0 1 1))

;; 新增一个 buffer + 一个视图。#:name 命名（默认 *scratch*）；#:focus? 控制是否把焦点交给新视图
;; （默认**不抢**）。返回 (values editor buffer-id)。
(define (editor-open-document ed text [height 24] [width 80]
                            #:name [name "*scratch*"] #:focus? [focus? #f])
  (define did (editor-next-document ed))
  (define entry (document-entry did name (document-open text) (history-empty)))
  (define ed1 (struct-copy editor ed
               [documents (append (editor-documents ed) (list entry))]
               [next-document (add1 did)]))
  (define-values (ed2 _vid) (editor-add-view ed1 did height width #:focus? focus?))
  (values ed2 did))

;; 新增一个视图。#:focus? 控制是否 focus 它（默认**不抢**）。返回 (values editor view-id)。
(define (editor-add-view ed did [height 24] [width 80] [p (point 0 0)]
                         #:sync [sync 'free] #:focus? [focus? #f])
  (check-sync 'editor-add-view sync)
  (define entry (editor-document-entry ed did))
  (define vid (editor-next-view ed))
  (define w (window-clamp-view
             (window-set-point (window-open (document-entry-document entry) height width) p)))
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

(define (editor-close-document ed did)
  (define d (document-entry-document (editor-document-entry ed did)))
  (define vs (filter (lambda (v) (not (eq? d (view-document v)))) (editor-views ed)))
  (define bs (filter (lambda (e) (not (= (document-entry-id e) did))) (editor-documents ed)))
  (define focus
    (cond [(null? vs) #f]
          [(for/or ([v (in-list vs)]) (= (view-id v) (editor-focus ed))) (editor-focus ed)]
          [else (view-id (car vs))]))
  (struct-copy editor ed [documents bs] [views vs] [focus focus]))

;;; ---------- 查询 ----------

;; 焦点 view 所属 document 的 id（focus 糖的默认 did）。
(define (focused-did ed) (editor-view-document-id ed (editor-focus ed)))

(define (editor-document-count ed) (length (editor-documents ed)))
(define (editor-view-count ed) (length (editor-views ed)))
(define (editor-document-id ed) (focused-did ed))
;; did 省略时用焦点 view 的 buffer（focus 糖）。
(define (editor-buffer ed [did (focused-did ed)]) (document-buffer (editor-document ed did)))
(define (editor-document ed [did (focused-did ed)]) (document-entry-document (editor-document-entry ed did)))
(define (editor-attrs ed [did (focused-did ed)]) (document-attrs (editor-document ed did)))
(define (editor-document-name ed [did (focused-did ed)]) (document-entry-name (editor-document-entry ed did)))
(define (editor-view-document-id ed vid) (document-id-of ed (view-document (editor-view-ref ed vid))))
(define (editor-view-buffer ed vid) (view-buffer (editor-view-ref ed vid)))
(define (editor-view-document ed vid) (view-document (editor-view-ref ed vid)))
(define (editor-view-sync ed vid) (view-sync (editor-view-ref ed vid)))
(define (editor-sync ed) (editor-view-sync ed (editor-focus ed)))

;; change-report 的行区间是 texts 与 attrs 的投影并集，读时现算。
(define (change-report-span r)
  (define-values (tf tl) (edits-span (change-report-texts r)))
  (define-values (af al)
    (for/fold ([f #f] [l #f]) ([a (in-list (change-report-attrs r))])
      (define line (point-line (attr-desc-start a)))
      (values (if f (min f line) line) (if l (max l line) line))))
  (values (cond [(and tf af) (min tf af)] [tf tf] [af af] [else #f])
          (cond [(and tl al) (max tl al)] [tl tl] [al al] [else #f])))
(define (change-report-first-line r)
  (let-values ([(f _) (change-report-span r)]) f))
(define (change-report-last-line r)
  (let-values ([( _ l) (change-report-span r)]) l))

(define (editor-focus-view ed vid)
  (editor-view-ref ed vid)                 ; 校验存在
  (struct-copy editor ed [focus vid]))

(define (editor-focus-document ed did)
  (define d (document-entry-document (editor-document-entry ed did)))
  (define v (for/first ([v (in-list (editor-views ed))] #:when (eq? d (view-document v))) v))
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
;; 选区集（命名 + 区间集 + leader）。组是 view 状态。
(define (editor-selection-set ed) (editor-view-selection-set ed (editor-focus ed)))
(define (editor-view-selection-set ed vid) (window-selection-set (view-window (editor-view-ref ed vid))))
(define (editor-selection-set-name ed) (editor-view-selection-set-name ed (editor-focus ed)))
(define (editor-view-selection-set-name ed vid) (window-selection-set-name (view-window (editor-view-ref ed vid))))
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
;;; face-provider : editor did line → (listof (list start end face))；投影时按需调用。
;;; 内部适配成 viewport 的 buffer 级 provider，应用不见 buffer。

(define (no-face-provider _ed _bid _line) '())

;; 把属性 buffer 的某个 key 物化成 face-provider。
(define (attrs-provider key)
  (lambda (ed did line) (editor-attr-key-runs ed did line key)))

(define (editor-view->screen ed vid [face-provider no-face-provider])
  (define did (editor-view-document-id ed vid))
  (window->screen (view-window (editor-view-ref ed vid))
                  (lambda (_b line) (face-provider ed did line))))
(define (editor->screen ed [face-provider no-face-provider])
  (editor-view->screen ed (editor-focus ed) face-provider))

;;; ---------- 点算子（editor 级：位置只认 point，buffer 由 did/vid 解析） ----------
;;; 应用写导航/扩选时不再需要拿 buffer / window。

(define (editor-point-left ed p) (point-left (editor-buffer ed (focused-did ed)) p))
(define (editor-view-point-left ed vid p) (point-left (editor-view-buffer ed vid) p))
(define (editor-point-right ed p) (point-right (editor-buffer ed (focused-did ed)) p))
(define (editor-view-point-right ed vid p) (point-right (editor-view-buffer ed vid) p))
(define (editor-point-home ed p) (point-home p))
(define (editor-view-point-home ed vid p) (point-home p))
(define (editor-point-end ed p) (point-end (editor-buffer ed (focused-did ed)) p))
(define (editor-view-point-end ed vid p) (point-end (editor-view-buffer ed vid) p))
(define (editor-point-up ed p) (point-up (editor-window ed) p))
(define (editor-view-point-up ed vid p) (point-up (editor-view-window ed vid) p))
(define (editor-point-down ed p) (point-down (editor-window ed) p))
(define (editor-view-point-down ed vid p) (point-down (editor-view-window ed vid) p))

;;; ---------- 文本 / 解析 / 属性读（按 buffer-id） ----------
;;; did 缺省 = 焦点 buffer；只有「ed 后只有一个参数」的读口能安全缺省
;;; （带 payload 时，位置缺省会与 payload 抢参数，故必须显式给 did）。

(define (editor-buffer->string ed [did (focused-did ed)]) (buffer->string (editor-buffer ed did)))
(define (editor-buffer->lines ed [did (focused-did ed)]) (buffer->lines (editor-buffer ed did)))
(define (editor-buffer-line-count ed [did (focused-did ed)]) (buffer-line-count (editor-buffer ed did)))
(define (editor-buffer-line-ref ed did i) (buffer-line-ref (editor-buffer ed did) i))
(define (editor-buffer-line-length ed did i) (buffer-line-length (editor-buffer ed did) i))
(define (editor-buffer-clamp-point ed did p) (buffer-clamp-point (editor-buffer ed did) p))
(define (editor-buffer-point->offset ed did p) (buffer-point->offset (editor-buffer ed did) p))
(define (editor-buffer-offset->point ed did off) (buffer-offset->point (editor-buffer ed did) off))
(define (editor-buffer-range-text ed did s e) (buffer-range-text (editor-buffer ed did) s e))
(define (editor-text-tick ed [did (focused-did ed)]) (buffer-tick (editor-buffer ed did)))
(define (editor-attr-tick ed [did (focused-did ed)]) (document-attr-tick (editor-document ed did)))
(define (editor-buffer-content-eq? ed b1 b2)
  (buffer-content-eq? (editor-buffer ed b1) (editor-buffer ed b2)))
(define (editor-attrs-eq? ed b1 b2)
  (document-attrs-eq? (editor-document ed b1) (editor-document ed b2)))
(define (editor-attr-at ed did p) (document-attr-at (editor-document ed did) p))
(define (editor-attr-runs ed did line) (document-attr-runs (editor-document ed did) line))
(define (editor-attr-key-runs ed did line key)
  (document-attr-key-runs (editor-document ed did) line key))

;;; ---------- 账本查询 ----------

(define (editor-can-undo? ed [did (focused-did ed)])
  (history-can-undo? (document-entry-history (editor-document-entry ed did))))
(define (editor-can-redo? ed [did (focused-did ed)])
  (history-can-redo? (document-entry-history (editor-document-entry ed did))))
(define (editor-undo-depth ed [did (focused-did ed)])
  (history-undo-depth (document-entry-history (editor-document-entry ed did))))
(define (editor-redo-depth ed [did (focused-did ed)])
  (history-redo-depth (document-entry-history (editor-document-entry ed did))))

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
  (check-equal? (editor-text-tick e0 0) 0)
  (check-equal? (editor-attr-tick e0 0) 0)
  (check-true (editor-buffer-content-eq? e0 0 0))
  (define-values (et _dt) (editor-apply-edit e0 0 (edit-desc (point 0 0) (point 0 0) "X")))
  (check-equal? (editor-text-tick et 0) 1)
  ;; 属性写只涨标注版本，不涨文本版本
  (define-values (et2 _et2r)
    (editor-apply-change et 0 (change/attrs (list (attr-set (point 0 0) (point 0 1) 'x #t)))))
  (check-equal? (editor-text-tick et2 0) 1)     ; 文本版本不变
  (check-equal? (editor-attr-tick et2 0) 1)       ; 标注版本 +1

  ;; 属性读：任意 key 的段；read-only 是保留 key
  (define-values (pr _prr)
    (editor-apply-change e0 0 (change/attrs (list (attr-set (point 0 0) (point 0 5) read-only-key #t)))))
  (check-equal? (editor-attr-runs pr 0 0) (list (list 0 5 (hash read-only-key #t))))
  (check-equal? (editor-attr-key-runs pr 0 0 read-only-key) (list (list 0 5 #t)))

  ;; 整体属性读 + 属性等价（与 editor-buffer / editor-buffer-content-eq? 对称）
  (check-equal? (editor-attrs pr) (document-attrs (editor-document pr 0)))
  (check-true (editor-attrs-eq? pr 0 0))
  (check-true (editor-attrs-eq? e0 0 0))

  ;; #:focus? #f：后台开 buffer 不抢焦点
  (define-values (e1 _bid) (editor-open-document e0 "BBB" #:name "b" #:focus? #f))
  (check-equal? (editor-document-id e1) 0)
  (check-equal? (editor-document-count e1) 2)

  ;; 结构变换：set-view-buffer 换属主、不改文本、不动焦点
  (define n1 (editor-set-view-document e1 0 1))
  (check-equal? (editor-view-document-id n1 0) 1)
  (check-equal? (editor-buffer->string n1 1) "BBB")

  ;; focus 糖默认 did：editor-buffer / 账本查询省略 did 时看焦点 buffer
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
  (define-values (pa _par)
    (editor-apply-change e0 0 (change/attrs (list (attr-set (point 0 0) (point 0 5) 'face (hash 'face 'keyword))))))
  (check-equal? (vector-ref (screen-row-runs (editor->screen pa (attrs-provider 'face))) 0)
                (list (run 0 "hello" (hash 'face 'keyword))))
  (check-equal? (vector-ref (screen-row-runs (editor->screen pa)) 0)
                (list (run 0 "hello" (hash))))

  (displayln "editor.rkt: all tests passed"))

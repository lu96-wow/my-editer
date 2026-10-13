#lang racket

;;; edit4-test/sidebar.rkt —— dock 尺寸策略：按朝向（左右算宽 / 上下算高）启动定一次，
;;; 夹上下限，运行时 resize 不变；显隐保持尺寸且不低于最小。

(require rackunit racket/list racket/file
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/core/world.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/region.rkt"
         "../edit4/content/placing.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/config/sidebar.rkt"
         "../edit4/boot.rkt")

;;; ---------- 纯函数：比例 + 上下限 ----------

(check-equal? (sidebar-width 1) sidebar-min-width)          ; 极窄 → 抬到 min
(check-true (<= sidebar-min-width (sidebar-width 80) sidebar-max-width))
(check-true (<= (sidebar-width 80) (sidebar-width 300)))    ; 单调不减
(check-equal? (sidebar-width 100000) sidebar-max-width)     ; 极宽 → 压到 max

(check-equal? (sidebar-height 1) sidebar-min-height)
(check-equal? (sidebar-height 100000) sidebar-max-height)

;;; ---------- 公共装置：显式声明朝向的 dock ----------

(define dir (make-temporary-file "ed4side~a" 'directory))
(define (left-spec) (list 'sidebar 'left 'auto (list "*tree*" "*buffers*") "*tree*" 'root 'shown 'auto))
(define (top-spec)  (list 'sidebar 'top  'auto (list "*tree*" "*buffers*") "*tree*" 'root 'shown 'auto))

(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))
(define SZ (cons 160 40))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (car (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list)))
(define (region-of w rid) (hash-ref (content-regions (world-content w)) rid))
(define (dock-rect w cols rows)
  (define r (region-of w 'sidebar))
  (define rects (geometry-rects (layout (world-layout w) (rect 0 0 cols rows))))
  (hash-ref rects (region-wid r)))
(define (dock-width w) (rect-w (dock-rect w (car SZ) (cdr SZ))))
(define (dock-height w) (rect-h (dock-rect w (car SZ) (cdr SZ))))

;;; ---------- 左侧 dock：按屏宽定宽；resize 不改 ----------

(define base (sidebar-width 160))
(define w (boot #:root dir #:screen-width 160 #:regions (list (left-spec))))
(check-not-false (region-wid (region-of w 'sidebar)))
(check-equal? (rect-w (dock-rect w 160 40)) base)     ; 启动宽度 = sidebar-width(屏宽)
(check-equal? (rect-w (dock-rect w 240 40)) base)     ; 运行时拉宽，dock 不动
(check-equal? (rect-w (dock-rect w 100 40)) base)     ; 运行时压窄，dock 不动（未触下限）
(check-equal? (region-size (region-of w 'sidebar)) base)

;; 屏宽更小 → 按比例缩小（但不低于 min）
(define wn (boot #:root dir #:screen-width 60 #:regions (list (left-spec))))
(check-equal? (rect-w (dock-rect wn 60 40)) (sidebar-width 60))

;;; ---------- 顶部 dock：auto 解析成**高度**（不是宽度）；resize 不改 ----------

(define hbase (sidebar-height 40))
(define wt (boot #:root dir #:screen-width 160 #:screen-height 40 #:regions (list (top-spec))))
(check-equal? (rect-h (dock-rect wt 160 40)) hbase)   ; 高度 = sidebar-height(屏高)
(check-equal? (rect-w (dock-rect wt 160 40)) 160)     ; 跨满宽
(check-equal? (rect-h (dock-rect wt 160 80)) hbase)   ; 运行时拉高，dock 不动
(check-equal? (region-size (region-of wt 'sidebar)) hbase)

;;; ---------- C-b 隐藏/显示：按隐藏时的尺寸恢复（用户拖过也一样） ----------

(define wb (boot #:root dir #:screen-width 160 #:regions (list (left-spec))))
(check-equal? (dock-width wb) base)
;; 拖缝把 dock 改宽（左侧：缝在 x = base）
(define d2 (run (run wb (cursor-event 'press 'left base 5))
                (cursor-event 'move 'left (+ base 12) 5)))
(define dragged (dock-width d2))
(check-not-equal? dragged base)                       ; 确实被拖宽
(define h1 (run d2 (key-event 'b '(ctrl))))           ; C-b 隐藏
(check-false (region-wid (region-of h1 'sidebar)))
(define h2 (run h1 (key-event 'b '(ctrl))))           ; C-b 显示
(check-not-false (region-wid (region-of h2 'sidebar)))
(check-equal? (dock-width h2) dragged)

;;; ---------- C-b：显示时有最小尺寸（拖到最小也不会“显不出来”） ----------

(define wc (boot #:root dir #:screen-width 160 #:regions (list (left-spec))))
(define wc1 (run (run wc (cursor-event 'press 'left base 5))
                 (cursor-event 'move 'left 0 5)))
(check-true (>= (dock-width wc1) sidebar-min-width))          ; 拖到底被 dock 最小尺寸兜住
(define wc2 (run wc1 (key-event 'b '(ctrl))))
(check-false (region-wid (region-of wc2 'sidebar)))
(define wc3 (run wc2 (key-event 'b '(ctrl))))
(check-true (>= (dock-width wc3) sidebar-min-width))

;;; ---------- 区域声明驱动：dock 可放顶部、顺序稳定 ----------

(define specs2 '((tree    top  6    ("*tree*")    "*tree*"    root shown)
                 (buffers left auto ("*buffers*") "*buffers*" root shown)
                 (log     bottom 6  ("*log*")     "*log*"     main hidden)))
(define wt2 (boot #:root dir #:screen-width 160 #:screen-height 40 #:regions specs2))
(define rects-t (geometry-rects (layout (world-layout wt2) (rect 0 0 160 40))))
(define tree-wid (region-wid (hash-ref (content-regions (world-content wt2)) 'tree)))
(check-not-false tree-wid)
(check-equal? (rect-y (hash-ref rects-t tree-wid)) 0)     ; 顶部
(check-equal? (rect-h (hash-ref rects-t tree-wid)) 6)     ; 显式高度
(check-true (> (rect-w (hash-ref rects-t tree-wid)) 0))  ; 另一条 root dock 在内层，宽不必满
(check-equal? (content-vid-of (world-content wt2) tree-wid)
              (content-panel-vid (world-content wt2) "*tree*"))

(define (geom-order w)
  (define rects (geometry-rects (layout (world-layout w) (rect 0 0 160 40))))
  (sort (for/list ([(id r) (in-hash rects)])
          (list (content-vid-of (world-content w) id) (rect-x r) (rect-y r) (rect-w r) (rect-h r)))
        (lambda (a b) (or (< (caddr a) (caddr b))
                          (and (= (caddr a) (caddr b)) (< (cadr a) (cadr b)))))))
(define before (geom-order wt2))
(define (toggle w rid) (car (run-commands region-commands #f w (list (cmd 'region-toggle rid)))))
(check-equal? (geom-order (toggle (toggle wt2 'tree) 'tree)) before)       ; 隐→显 tree
(check-equal? (geom-order (toggle (toggle wt2 'buffers) 'buffers)) before) ; 隐→显 buffers

;;; ---------- 关掉最后一个编辑器窗后再打开文件：新窗回主区（main dock 反侧），
;;; 不被嵌进顶部 dock 所在的横带里（回归：C-d 后打开文件跑到树右侧）。

(define wclose (boot #:root dir #:screen-width 160 #:screen-height 40 #:regions (list (top-spec))))
(define lay0 (remove-leaf (world-layout wclose) 0))          ; 关掉主区编辑器
(define wclosed (world-set-layout wclose lay0))
(define-values (ccl _cd cv) (content-add-doc! (world-content wclosed) "hi" 40 10 "a.rkt" #f))
(define wnew (place-vid! (world-set-content wclosed ccl) cv))
(define root (world-layout wnew))
(check-true (split? root))
(check-equal? (split-axis root) 'v)                          ; 根仍是纵向：树在上、主区在下
(define path-new (path-of root (world-focus wnew)))
(check-equal? (length path-new) 1)                           ; 新窗是根的直接孩子
(check-equal? (leaf-id (node-at root (list 0)))
              (region-leaf (region-of wclosed 'sidebar)))    ; 顶部第一格仍是树

;;; ---------- C-d 关掉最后一个编辑器窗：空占位保留，dock / 主区尺寸不漂 ----------

(define wsd (boot #:root dir #:screen-width 160 #:screen-height 40))
(define rsb (region-of wsd 'sidebar))
(define rst (region-of wsd 'status))
(define eds (content-editor-window (world-content wsd) (world-layout wsd)))
(define (h-of-leaf w id)
  (rect-h (hash-ref (geometry-rects (layout (world-layout w) (rect 0 0 160 40))) id)))
(check-not-false eds)
(define sb-h0 (h-of-leaf wsd (region-leaf rsb)))
(define st-h0 (h-of-leaf wsd (region-leaf rst)))
(define ed-h0 (h-of-leaf wsd eds))

(define wsd* (run wsd (key-event 'd '(ctrl))))               ; C-d 关最后一个编辑器
(check-true (has-id? wsd* eds))                              ; 叶子仍在（空占位）
(check-false (content-vid-of (world-content wsd*) eds))      ; 但已无视图
(check-equal? (h-of-leaf wsd* (region-leaf rsb)) sb-h0)      ; 树尺寸不变
(check-equal? (h-of-leaf wsd* (region-leaf rst)) st-h0)      ; 状态栏尺寸不变
(check-equal? (h-of-leaf wsd* eds) ed-h0)                    ; 主区尺寸不变

;; 再打开文件 → 直接用这个空占位（单窗直放），继续不漂
(define-values (cws _dws cvs) (content-add-doc! (world-content wsd*) "hi" 40 10 "x.rkt" #f))
(define wsd2 (place-vid! (world-set-content wsd* cws) cvs))
(check-eqv? (world-focus wsd2) eds)
(check-equal? (h-of-leaf wsd2 (region-leaf rsb)) sb-h0)

(displayln "edit4/sidebar.rkt: all tests passed")

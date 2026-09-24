#lang racket

;;; ============================================================================
;;; demo/two-pane-editor.rkt —— racket-tui 双窗口编辑器（左右同步）
;;; ============================================================================
;;;
;;;   racket demo/two-pane-editor.rkt
;;;
;;; 一个文档，两个视图（同尺寸、左右并排）：
;;;   · 左视图 = 主导（焦点），右视图 sync='follow 跟随；
;;;   · 编辑 / 导航 / 滚动 → 右边自动镜像，两边永远一致；
;;;   · 渲染走 core 的增量链路：projection 增量 → composition 增量 → frame-damage；
;;;   · 需要整屏时走全量 API（compose-panes / frame->draw-list）。
;;;
;;; 按键：
;;;   可打印字符 / 粘贴   输入
;;;   Enter / Tab / Backspace / Delete
;;;   ← → ↑ ↓  Home End  PgUp PgDn
;;;   Ctrl+Z 撤销   Ctrl+Y 重做   Ctrl+Q 退出
;;;   鼠标左键定位 / 滚轮滚动

(require (except-in tui key-event key-event? key-event-key struct:key-event
                          resize-event resize-event? resize-event-rows resize-event-cols
                          struct:resize-event)
         "../core/editor.rkt"
         "../core/api.rkt"
         "../core/target.rkt"
         racket/string)

;;; ---------- 默认文本 ----------

(define default-text
  (string-join
   '("racket-tui 双窗口编辑器"
     "========================================"
     ""
     "左边是主视图（焦点），右边是同步跟随视图。"
     "两边内容、光标、滚动始终保持同步。"
     ""
     "可以试试："
     "  · 随便输入一些文字"
     "  · 方向键 / Home / End / PgUp / PgDn 移动光标"
     "  · Ctrl+Z 撤销 / Ctrl+Y 重做"
     "  · Shift+方向键 选中；Ctrl+A 选中所有相同字符/文本（多选区）"
     "  · 鼠标点一下定位 / 滚轮滚动"
     "  · Ctrl+Q 退出"
     ""
     "中文 / English / 全角：中文字符占两列。"
     "下面这行用来测长行滚动与光标列换算："
     "0123456789 abcdefghijklmnopqrstuvwxyz 0123456789 abcdefghijklmnopqrstuvwxyz")
   "\n"))

;;; ---------- 编辑器状态 ----------

(define ed-box (box #f))
(define rows-box (box 24))   ; 终端总行数
(define cols-box (box 80))   ; 终端总列数
(define dirty-box (box '())) ; 本次编辑改动的缓冲行（供增量投影）
(define quit? (box #f))

;; 左右两块正文宽度（相同），中间留 1 列 gutter。
(define (pane-width)
  (max 4 (quotient (- (unbox cols-box) 2) 2)))
(define (pane-rows) (max 2 (unbox rows-box)))   ; 窗格占满全屏
(define (right-x) (add1 (pane-width)))

(define (setup! rows cols)
  ;; 次光标也要是「块」：背景块，而不是前景色（否则只把字染色、看着不像光标）
  (style-define! 'cursor-secondary clr-black bclr-yellow)
  (define pw (max 4 (quotient (- cols 2) 2)))
  (define ph (max 2 rows))
  (set-box! rows-box rows)
  (set-box! cols-box cols)
  (define ed0 (editor-open default-text ph pw #:name "*two-pane*" #:line-numbers? #t))
  (define-values (ed1 _vid1) (editor-add-view ed0 0 ph pw #:sync 'follow #:line-numbers? #t))
  (set-box! ed-box ed1)
  (set-box! cache-box (rcache #f (hash) (hash)))
  (set-box! dirty-box '()))

;;; ---------- 渲染缓存（增量用） ----------

(struct rcache (comp projs wins) #:transparent)   ; comp : composition/#f ；projs/wins : vid → 值
(define cache-box (box (rcache #f (hash) (hash))))

(define (face->style attr)
  (and (hash? attr)
       (case (hash-ref attr 'face #f)
         [(cursor) (if (hash-ref attr 'primary? #f) 'cursor 'cursor-secondary)]  ; 主=白底块，次=黄底块
         [(selection) 'selection]
         [(line-number) 'status-bar]
         [(keyword) 'info]
         [else #f])))

;; 绘制一帧（增量）：只擦脏矩形、只画修补绘制项。
(define (draw!)
  (define ed (unbox ed-box))
  (define rows (unbox rows-box))
  (define cols (unbox cols-box))
  (define ph (pane-rows))
  (define pw (pane-width))
  (define rx (right-x))
  (define c (unbox cache-box))
  (define changed-lines (unbox dirty-box))
  (set-box! dirty-box '())

  ;; 1) 每个视图的 projection：窗口没变就复用，变了就增量投影
  (define new-projs (make-hash))
  (define new-wins (make-hash))
  (define dirty-map (make-hash))
  (for ([vid (in-list '(0 1))])
    (define w (editor-view-window ed vid))
    (define oldp (hash-ref (rcache-projs c) vid #f))
    (define oldw (hash-ref (rcache-wins c) vid #f))
    (cond
      [(and oldp (equal? w oldw))
       (hash-set! new-projs vid oldp)
       (hash-set! new-wins vid w)]
      [else
       (define-values (p dr) (window->projection/incremental oldp w changed-lines))
       (hash-set! new-projs vid p)
       (hash-set! new-wins vid w)
       (hash-set! dirty-map vid dr)]))

  ;; 2) 合成（增量）
  (define panes (list (pane 0 0 0 (projection-screen (hash-ref new-projs 0)))
                      (pane 1 rx 0 (projection-screen (hash-ref new-projs 1)))))
  (define old-comp (rcache-comp c))
  (define-values (comp2 dirty-rows)
    (if old-comp
        (composition-refresh old-comp ph cols panes 0 dirty-map)
        (values (compose-panes ph cols panes 0)
                (for/list ([r (in-range ph)]) r))))

  ;; 3) 脏矩形 + 修补绘制项
  (define old-screen (if old-comp (composition-screen old-comp) #f))
  (define new-screen (composition-screen comp2))
  (define-values (rects items)
    (if old-screen
        (frame-damage old-screen new-screen dirty-rows)
        (values #f (frame->draw-list new-screen))))

  ;; 4) 输出
  (define parts (list format-cursor-hide))
  (define (emit! b) (set! parts (cons b parts)))
  (cond
    [(not rects)
     (emit! format-screen-clear)
     (for ([it (in-list items)]) (emit-item! emit! it))]
    [else
     (for ([r (in-list rects)])
       (emit! (format-cursor-move (add1 (rect-y r)) (add1 (rect-x r))))
       (emit! (format-content (make-string (rect-width r) #\space))))
     (for ([it (in-list items)]) (emit-item! emit! it))])
  ;; 没有状态栏：合成帧占满整屏。注意不要写终端右下角那一格（会触发自动换行/滚屏）。
  (emit! format-cursor-hide)
  (put-bytes (apply bytes-append (reverse parts)))

  (set-box! cache-box (rcache comp2 new-projs new-wins)))

(define (emit-item! emit! it)
  (emit! (format-cursor-move (add1 (draw-item-y it)) (add1 (draw-item-x it))))
  (define st (face->style (draw-item-attr it)))
  (emit! (if st
             (bytes-append (style->bytes st) (format-content (draw-item-text it)) format-reset)
             (format-content (draw-item-text it)))))


;;; ---------- 命令 → 编辑器 → 标记脏行 ----------

(define (report->lines r)
  (define a (change-report-first-line r))
  (define b (change-report-last-line r))
  (if a (for/list ([i (in-range a (add1 b))]) i) '()))

;; f : editor → (values editor report/#f)
(define (apply! f)
  (define-values (ed2 report) (f (unbox ed-box)))
  (set-box! ed-box ed2)
  (set-box! dirty-box (if report (report->lines report) '()))
  (draw!))

(define (edit! op) (apply! (lambda (ed) (editor-edit ed op))))
(define (nav! f)   (apply! (lambda (ed) (values (f ed) #f))))

;;; ---------- 鼠标 ----------

(define (mouse-goto! x y)
  (define pw (pane-width))
  (define rx (right-x))
  (define vid (cond [(< x pw) 0] [(>= x rx) 1] [else #f]))
  (when vid
    (define lx (if (= vid 0) x (- x rx)))
    (define-values (line col) (editor-view-screen->point (unbox ed-box) vid y lx))
    (when line
      (nav! (lambda (ed) (editor-goto ed (point line col)))))))

(define (page-step) (max 1 (sub1 (pane-rows))))

;;; ---------- Shift 扩选 ----------

;; 对主选区的头部施 f（位置→位置），即 Shift+方向键。f : editor → 位置 → 位置。
(define (shift-extend! f)
  (apply! (lambda (ed)
            (values (editor-map-primary ed (lambda (s) (selection-map-head (lambda (p) (f ed p)) s)))
                    #f))))

;;; ---------- Ctrl+A：匹配所有相同字符 / 相同文本 → 多选区 ----------

;; 全文里 pat 的所有非重叠出现：((start . end) ...)。
(define (find-all text pat)
  (define n (string-length text))
  (define m (string-length pat))
  (if (zero? m)
      '()
      (let loop ([i 0] [acc '()])
        (cond
          [(> (+ i m) n) (reverse acc)]
          [(string=? (substring text i (+ i m)) pat) (loop (+ i m) (cons (cons i (+ i m)) acc))]
          [else (loop (add1 i) acc)]))))

;; 光标处的单个字符（列 = 字符索引）：优先取光标后，行尾则取光标前。
(define (char-at-cursor ed did)
  (define p (editor-point ed))
  (define line (editor-document-line-ref ed did (point-line p)))
  (define c (point-col p))
  (cond [(< c (string-length line)) (substring line c (add1 c))]
        [(> c 0) (substring line (sub1 c) c)]
        [else #f]))

;; 有选区 → 用选区文本；没选区 → 用光标处一个字符。选中所有匹配。
(define (match-all!)
  (apply!
   (lambda (ed)
     (define did (editor-document-id ed))
     (define sel (editor-primary ed))
     (define pat
       (if (selection-empty? sel)
           (char-at-cursor ed did)
           (let-values ([(a b) (selection-range sel)])
             (editor-document-range-text ed did a b))))
     (define sels
       (if (or (not pat) (string=? pat ""))
           (list sel)
           (for/list ([m (in-list (find-all (editor-document->string ed did) pat))])
             (selection (editor-document-offset->point ed did (car m))
                        (editor-document-offset->point ed did (cdr m))))))
     (values (editor-set-selections ed sels 0) #f))))

;;; ---------- 事件处理 ----------

(define (make-handler)
  (build-input
   #:text      (lambda (s) (edit! (edit-insert s)))
   #:enter     (lambda () (edit! (edit-newline)))
   #:tab       (lambda () (edit! (edit-insert "\t")))
   #:backspace (lambda () (edit! (edit-backspace)))
   #:delete    (lambda () (edit! (edit-delete)))
   #:left      (lambda () (nav! editor-left))
   #:right     (lambda () (nav! editor-right))
   #:up        (lambda () (nav! editor-up))
   #:down      (lambda () (nav! editor-down))
   #:home      (lambda () (nav! editor-home))
   #:end       (lambda () (nav! editor-end))
   #:pageup    (lambda () (nav! (lambda (ed) (editor-scroll ed (- (page-step))))))
   #:pagedown  (lambda () (nav! (lambda (ed) (editor-scroll ed (page-step)))))
   #:escape    (lambda () (nav! editor-collapse-selections))
   #:key       (lambda (key mods)
                 (cond
                   ;; Ctrl+字母
                   [(and (char? key) (mods-ctrl? mods))
                    (case (char-downcase key)
                      [(#\z) (apply! editor-undo)]
                      [(#\y) (apply! editor-redo)]
                      [(#\a) (match-all!)]           ; Ctrl+A：匹配所有相同字符/文本
                      [(#\q) (set-box! quit? #t)]
                      [else (void)])]
                   ;; Shift+命名键 → 扩选
                   [(and (symbol? key) (mods-shift? mods) (not (mods-ctrl? mods)))
                    (case key
                      [(left)  (shift-extend! editor-point-left)]
                      [(right) (shift-extend! editor-point-right)]
                      [(up)    (shift-extend! editor-point-up)]
                      [(down)  (shift-extend! editor-point-down)]
                      [(home)  (shift-extend! editor-point-home)]
                      [(end)   (shift-extend! editor-point-end)]
                      [else (void)])]
                   [else (void)]))
   #:mouse     (lambda (action button x y _mods)
                 (case action
                   [(press) (when (eq? button 'left) (mouse-goto! x y))]
                   [(scroll) (nav! (lambda (ed)
                                     (editor-scroll ed (if (eq? button 'up) -3 3))))]
                   [else (void)]))
   #:resize    (lambda (rows cols)
                 (define pw (max 4 (quotient (- cols 2) 2)))
                 (define ph (max 2 rows))
                 (set-box! rows-box rows)
                 (set-box! cols-box cols)
                 (set-box! ed-box
                           (editor-view-set-size
                            (editor-view-set-size (unbox ed-box) 0 ph pw)
                            1 ph pw))
                 (set-box! cache-box (rcache #f (hash) (hash)))   ; 几何变 → 全量
                 (draw!))))

;;; ---------- 主循环 ----------

(module+ main
  (with-tui
   (lambda ()
     (enable-bracketed-paste!)
     (define-values (r0 c0) (get-window-size))
     (setup! (max 4 (or r0 24)) (max 12 (or c0 80)))
     (define handler (make-handler))
     (draw!)
     (loop-input/stop (unbox quit?) handler))))

;;; ---------- 测试（无 TTY：只验核心同步 + 增量渲染） ----------

(module+ test
  (require rackunit)

  ;; 两视图同文档、同步跟随
  (define ed (editor-open "aaaa\nbbbb\ncccc" 3 8 #:line-numbers? #t))
  (define-values (ed2 _v1) (editor-add-view ed 0 3 8 #:sync 'follow #:line-numbers? #t))
  (check-equal? (editor-view-point ed2 0) (editor-view-point ed2 1))

  ;; 焦点视图编辑 → 跟随视图光标一致
  (define-values (ed3 rpt) (editor-edit ed2 (edit-insert "X")))
  (check-equal? (editor-view-point ed3 0) (editor-view-point ed3 1))
  (check-equal? (editor-view-point ed3 0) (point 0 1))
  (check-equal? (editor-document->string ed3 0) "Xaaaa\nbbbb\ncccc")

  ;; 两视图内容一致（同一文档）
  (check-equal? (editor-view-buffer ed3 0) (editor-view-buffer ed3 1))

  ;; 增量渲染：同长度替换第 1 行首字符 → 每个窗格只脏 1 列，合成后 2 列
  (define e0 (editor-open "aaaa\nbbbb\ncccc" 3 8))            ; 无行号
  (define-values (e1 _v) (editor-add-view e0 0 3 8 #:sync 'follow))
  (define pa (window->projection (editor-view-window e1 0)))
  (define pb (window->projection (editor-view-window e1 1)))
  (define comp0 (compose-panes 3 20 (list (pane 0 0 0 (projection-screen pa))
                                          (pane 1 10 0 (projection-screen pb))) 0))
  (define-values (e2 r2) (editor-document-edit-at e1 0 (point 1 0) (edit-splice (point 1 0) (point 1 1) "Y")))
  (define dlines (report->lines r2))
  (check-equal? dlines '(1))
  (define-values (pa2 da) (window->projection/incremental pa (editor-view-window e2 0) dlines))
  (define-values (pb2 db) (window->projection/incremental pb (editor-view-window e2 1) dlines))
  (check-equal? da '(1))
  (check-equal? db '(1))
  (check-equal? (editor-document->string e2 0) "aaaa\nYbbb\ncccc")
  (define-values (comp1 cd)
    (composition-refresh comp0 3 20
                         (list (pane 0 0 0 (projection-screen pa2))
                               (pane 1 10 0 (projection-screen pb2)))
                         0 (hash 0 da 1 db)))
  (check-equal? cd '(1))
  (define-values (rects _items)
    (frame-damage (composition-screen comp0) (composition-screen comp1) cd))
  (check-equal? rects (list (rect 0 1 1 1) (rect 10 1 1 1)))   ; 左窗格 + 右窗格各 1 列

  ;; Shift 扩选：主选区头部右移 → 选区变长
  (define es (editor-open "abcdef" 2 10))
  (define es1 (editor-map-primary es (lambda (s) (selection-map-head (lambda (p) (editor-point-right es p)) s))))
  (check-equal? (editor-selections es1) (list (selection (point 0 0) (point 0 1))))
  (define es2 (editor-map-primary es1 (lambda (s) (selection-map-head (lambda (p) (editor-point-right es1 p)) s))))
  (check-equal? (editor-selections es2) (list (selection (point 0 0) (point 0 2))))

  ;; 多选区渲染：4 个选区 → 4 光标 + 4 选中段，宽度各 2
  (define em (editor-open "ab ab\nab ab" 3 12))
  (define em2 (editor-set-selections em
                                     (list (selection (point 0 0) (point 0 2))
                                           (selection (point 0 3) (point 0 5))
                                           (selection (point 1 0) (point 1 2))
                                           (selection (point 1 3) (point 1 5)))))
  (define mitems (frame->draw-list (projection-screen (window->projection (editor-view-window em2 0)))))
  (define (at-layer n items) (filter (lambda (it) (= (draw-item-layer it) n)) items))
  (check-equal? (length (at-layer cursor-layer mitems)) 4)
  (check-equal? (length (at-layer selection-layer mitems)) 4)
  (check-equal? (map draw-item-width (at-layer selection-layer mitems)) '(2 2 2 2))

  ;; Ctrl+A 语义：在 "ab ab ab" 上匹配 "ab" → 3 个选区 + 3 光标
  (define ea (editor-open "ab ab ab" 2 12))
  (check-equal? (find-all (editor-document->string ea 0) "ab") '((0 . 2) (3 . 5) (6 . 8)))
  (define ea2 (editor-set-selections ea
                                     (for/list ([m (in-list (find-all (editor-document->string ea 0) "ab"))])
                                       (selection (editor-document-offset->point ea 0 (car m))
                                                  (editor-document-offset->point ea 0 (cdr m))))
                                     0))
  (define aitems (frame->draw-list (projection-screen (window->projection (editor-view-window ea2 0)))))
  (check-equal? (length (at-layer selection-layer aitems)) 3)
  (check-equal? (length (at-layer cursor-layer aitems)) 3)
  (check-equal? (map draw-item-x (at-layer selection-layer aitems)) '(0 3 6))

  ;; 宽字符多选区：每个选中段覆盖一个中文字（宽 2），光标在其头
  (define ew (editor-open "中中中" 2 10))
  (define ew2 (editor-set-selections ew (list (selection (point 0 0) (point 0 1))
                                              (selection (point 0 1) (point 0 2)))))
  (define witems (frame->draw-list (projection-screen (window->projection (editor-view-window ew2 0)))))
  (check-equal? (map draw-item-text (at-layer selection-layer witems)) '("中" "中"))
  (check-equal? (map draw-item-width (at-layer selection-layer witems)) '(2 2))
  (check-equal? (map draw-item-x (at-layer cursor-layer witems)) '(2 4))   ; 头分别在两个字起点

  (displayln "two-pane-editor.rkt: all tests passed"))

#lang racket

;;; edit-rebuild/core/session/adapter.rkt —— core 边界（唯一 require core/editor 的模块）
;;;
;;; 局部问题：把 core/editor（文档 / 视图 / 几何 / 渲染）适配成会话可用的读 + 写原语，
;;; 以及由几何组合出的「已落位窗格」。
;;;
;;; 其余 session-* / feature / plugin 都只走本模块的适配函数，不直接碰 core。
;;;
;;; 本文件是会话里唯一认识 core/editor 的地方（依赖方向：会话 → core，单向）。

(require "session.rkt"
         "../doc/catalog.rkt"
         "../geometry/layout.rkt"
         "../geometry/layout.rkt"
         "../surface/surface.rkt"
         "../face/face.rkt"
         "../face/line-scan.rkt"
         "../keymap.rkt"
         "../../../core/editor.rkt"
         "../../../core/text/document.rkt"
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/range.rkt"
         "../../../core/text/base/track.rkt"
         "../../../core/text/base/line.rkt"
         (only-in "../../../core/text/slot-dsl.rkt" define-document-slot)
         (only-in "../../../core/text/slots.rkt" fork-ctx-changes fork-ctx-new-text fork-ctx-old-text)
         "../../../core/view/compose.rkt"
         "../../../core/view/base/screen.rkt")

(provide
 session-blank
 panel-doc
 input-document
 ;; 几何 / 渲染
 session-views session-panes session-rectangles session-patch sync-layout!
 session-pane-inset
 ;; piece 词汇（由 core 重导）
 piece piece? piece-row piece-column piece-text piece-attr
 session-focused-did
 ;; 文档 / 视图结构 + 读
 session-add-document session-add-view
 session-document-ids session-view-ids-of session-document-name
 session-overlay-dids
 session-view-did session-view-point session-view-point-line
 session-view-point-column session-view-point->screen session-view-cursor-screen
 session-view-width session-view-height session-view-line-numbers? session-view-string
 session-view-id-list session-document-view-list
 session-document-handle session-document-track
 session-document-string session-mark-saved session-dirty?
 define-document-slot session-doc-slot-ref session-doc-slot-set!
 fork-ctx-changes fork-ctx-old-text fork-ctx-new-text
 session-doc-face-lines!
 session-ed-replace!
 ;; 内核适配
 session-ed-close-view session-ed-close-document
 session-ed-assign! session-ed-set-point! session-ed-screen->point
 session-ed-scroll! session-ed-hscroll! session-ed-nav!
 session-ed-select-all! session-ed-copy! session-ed-cut! session-ed-paste!
 session-ed-insert! session-ed-delete! session-ed-backspace!
 session-ed-undo! session-ed-redo!)

;;; ---------- 空会话 ----------

(define (session-blank width height [keys '()])
  (session-new-blank (make-blank-editor) width height keys))

;;; ---------- 面板文档 ----------

;; rows : (listof (list 文本 face|#f))
(define (panel-doc rows)
  (define lines (for/list ([r (in-list rows)]) (first r)))
  (define doc (document-open (string-join lines "\n")))
  (document-face-fill-batch
   doc (for/list ([r (in-list rows)] [l (in-list lines)] [i (in-naturals)]
                  #:when (second r))
         (list i 0 i (string-length l) (second r))))
  (document-readonly-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length l) #t)))
  doc)

;; 输入行文档：label 段只读（不可删改），其后可写。
(define (input-document label)
  (define doc (document-open label))
  (when (positive? (string-length label))
    (document-readonly-fill-batch
     doc (list (list 0 0 0 (string-length label) #t))))
  doc)

;;; ---------- 几何 ----------

(define (session-views s)
  (layout-place (session-layout s) (session-bindings s)
                (lambda (vid) (session-visible? s vid))
                (area 0 0 (session-width s) (session-height s))))

;; 面的边框 face（#f = 无边框）。
(define (surface-border-of s vid)
  (define sf (session-surface-for-vid s vid))
  (and sf (surface-border sf)))

;; 内容内缩量：有边框的面内容四周各让 1 格。
(define (session-pane-inset s vid)
  (if (surface-border-of s vid) 1 0))

;; 内容矩形（有边框则内缩 1）；渲染 / 设尺寸都用它。
(define (session-content-panes s)
  (for/list ([p (in-list (session-panes s))])
    (define ins (session-pane-inset s (placed-vid p)))
    (if (zero? ins)
        p
        (placed (placed-vid p)
                (+ (placed-x p) ins) (+ (placed-y p) ins)
                (max 1 (- (placed-w p) (* 2 ins))) (max 1 (- (placed-h p) (* 2 ins)))
                (placed-deep p)))))

(define (session-rectangles s)
  (for/list ([p (in-list (session-content-panes s))])
    (rectangle (placed-vid p) (placed-x p) (placed-y p) (placed-w p) (placed-h p)
               (placed-deep p))))

;; 浮动面 → placed（每帧按 pos 产出；#f = 本帧不显示）。
(define (session-surface-placed s)
  (append*
   (for/list ([sf (in-list (session-surfaces s))] #:when (surface-float? sf))
     (define pl (surface-placement sf))
     (define r ((float-pos pl) s))
     (if r
         (list (placed (surface-vid sf) (area-x r) (area-y r)
                       (area-w r) (area-h r) (float-deep pl)))
         '()))))

;; 所有已落位窗格：布局树 + 浮动面，按 deep 升序（大的在上）。
(define (session-panes s)
  (sort (append (session-views s) (session-surface-placed s)) < #:key placed-deep))

(define (session-focused-did s)
  (define vid (session-focus-vid s))
  (and vid (editor-view-document-id (session-ed s) vid)))

(define (sync-layout! s)
  (editor-set-layout! (session-ed s) (session-rectangles s)))

;;; ---------- 边框（按连接方向取交点字形） ----------

;; 方向集合规范序：d < l < r < u（按符号名排序）→ 字形。
(define border-glyphs
  (hash '(d r)       #\┌
        '(d l)       #\┐
        '(r u)       #\└
        '(l u)       #\┘
        '(l r)       #\─
        '(d u)       #\│
        '(d r u)     #\├
        '(d l u)     #\┤
        '(d l r)     #\┬
        '(l r u)     #\┴
        '(d l r u)   #\┼))

(define (canon-dirs ds)
  (sort (remove-duplicates (filter symbol? ds))
        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))

(define (conn->char conns cx cy)
  (hash-ref border-glyphs (canon-dirs (hash-ref conns (cons cx cy) '())) #\space))

(define (add-conn! h cx cy d)
  (define k (cons cx cy))
  (hash-set! h k (cons d (hash-ref h k '()))))

;; 一个矩形四边加入连接方向（角上同时带横向与纵向）。
(define (rect-add-conns! h x y w hh)
  (define x2 (+ x w -1))
  (define y2 (+ y hh -1))
  (for ([c (in-range x (+ x w))])
    (unless (= c x2) (add-conn! h c y 'r) (add-conn! h c y2 'r))
    (unless (= c x)  (add-conn! h c y 'l) (add-conn! h c y2 'l)))
  (add-conn! h x y 'd) (add-conn! h x y2 'u)     ; 角：上/下边在角处向下/上
  (add-conn! h x2 y 'd) (add-conn! h x2 y2 'u)
  (for ([r (in-range (add1 y) y2)])
    (add-conn! h x r 'u) (add-conn! h x r 'd)
    (add-conn! h x2 r 'u) (add-conn! h x2 r 'd)))

;; 一个方框的边框屏（上/下边整行，中间行只左右两格）。
(define (border-screen conns x y w hh face)
  (define x2 (+ x w -1))
  (define rows
    (build-vector hh
      (lambda (rr)
        (define gy (+ y rr))
        (cond
          [(or (= rr 0) (= rr (sub1 hh)))
           (list (run 0 (list->string (for/list ([cc (in-range x (+ x w))])
                                       (conn->char conns cc gy))) face))]
          [else
           (list (run 0 (string (conn->char conns x gy)) face)
                 (run (sub1 w) (string (conn->char conns x2 gy)) face))]))))
  (screen w hh rows '() '()))

;; 有边框的窗格 → 边框 pane（deep 比内容低 1）。多个边框共享边时，交点取 T 字形。
(define (session-border-panes s)
  (define rects
    (for/list ([p (in-list (session-panes s))]
               #:when (surface-border-of s (placed-vid p)))
      (list (placed-x p) (placed-y p) (placed-w p) (placed-h p)
            (surface-border-of s (placed-vid p)) (placed-deep p))))
  (define conns (make-hash))
  (for ([r (in-list rects)])
    (rect-add-conns! conns (first r) (second r) (third r) (fourth r)))
  (for/list ([r (in-list rects)])
    (match-define (list x y w hh face deep) r)
    (pane 'window-border y x (border-screen conns x y w hh face) (sub1 deep))))

;;; ---------- 渲染 ----------

(define (session-patch s old)
  (editor-render-layout-patch (session-ed s) old (session-rectangles s)
                              (session-focus-vid s) (session-width s) (session-height s)
                              (session-border-panes s)))

;;; ---------- 文档 / 视图结构 ----------

(define (session-add-document s doc width height
                              #:name [name "*scratch*"]
                              #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* did) (editor-add-document (session-ed s) doc name))
  (define-values (ed** vid) (editor-add-view ed* did width height
                                             #:mode mode #:line-numbers? line-numbers?))
  (values (session-set-doc-keymap (struct-copy session s [ed ed**]) did (kbd)) did vid))

(define (session-add-view s did width height
                          #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* vid) (editor-add-view (session-ed s) did width height
                                            #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s [ed ed*]) vid))

;;; ---------- 读 ----------

(define (session-document-ids s) (editor-document-id-list (session-ed s)))
(define (session-view-ids-of s did) (editor-document-view-list (session-ed s) did))
(define (session-document-name s did) (editor-document-name (session-ed s) did))
(define (session-view-did s vid) (editor-view-document-id (session-ed s) vid))
(define (session-view-point s vid) (editor-view-point (session-ed s) vid))
(define (session-view-point-line s vid) (editor-view-point-line (session-ed s) vid))
(define (session-view-point-column s vid) (editor-view-point-column (session-ed s) vid))

(define (session-view-point->screen s vid line col)
  (define pl (for/first ([p (in-list (session-views s))] #:when (eqv? vid (placed-vid p))) p))
  (cond
    [(not pl) (values #f #f)]
    [else
     (define ins (session-pane-inset s vid))
     (define-values (r c) (editor-view-point->screen-position (session-ed s) vid (point line col)))
     (if r
         (values (+ (placed-x pl) ins c) (+ (placed-y pl) ins r))
         (values (+ (placed-x pl) ins) (+ (placed-y pl) ins)))]))

(define (session-view-cursor-screen s vid)
  (session-view-point->screen s vid (session-view-point-line s vid)
                              (session-view-point-column s vid)))

(define (session-overlay-dids s)
  (for/list ([vid (in-list (session-overlays s))]) (session-view-did s vid)))
(define (session-view-width s vid) (editor-view-width (session-ed s) vid))
(define (session-view-height s vid) (editor-view-height (session-ed s) vid))
(define (session-view-line-numbers? s vid) (editor-view-line-numbers? (session-ed s) vid))
(define (session-view-string s vid) (editor-view-string (session-ed s) vid))
(define (session-view-id-list s) (editor-view-id-list (session-ed s)))
(define (session-document-view-list s did) (editor-document-view-list (session-ed s) did))
(define (session-document-string s did) (editor-document-string (session-ed s) did))
(define (session-document-handle s did) (editor-document-handle (session-ed s) did))

;;; ---------- 文档槽 ----------

(define (session-doc-slot-ref s did sl) (editor-document-slot-ref (session-ed s) did sl))
(define (session-doc-slot-set! s did sl v) (editor-document-slot-set! (session-ed s) did sl v) s)

;;; ---------- 文档文本轨 ----------

(define (session-document-track s did)
  (document-text (session-document-handle s did)))

;;; ---------- 写回原语（按行增量） ----------

(define (session-doc-face-lines! s did layers dirty)
  (define doc (session-document-handle s did))
  (define text (document-text doc))
  (define n (track-length text))
  (define lines (dirty->lines dirty n))
  (document-face-fill-batch
   doc
   (for/list ([run (in-list (contiguous-runs lines))])
     (define hi (sub1 (cdr run)))
     (list (car run) 0 hi (track-line-length text hi) #f)))
  (for ([layer (in-list layers)])
    (document-face-fill-batch*
     doc
     (append* (for/list ([ln (in-list lines)]
                         #:when (< ln (track-length layer)))
                (define vec (track-ref layer ln))
                (if vec
                    (for/list ([r (in-list (face-runs vec))])
                      (list ln (car r) ln (cadr r) (caddr r)))
                    '())))
     face-compose))
  s)

(define (session-ed-replace! s vid l0 c0 l1 c1 text)
  (define ed (session-ed s))
  (editor-view-set-selections! ed vid (selections-one (selection (point l0 c0) (point l1 c1))))
  (editor-view-insert! ed vid text)
  s)

;;; ---------- 保存句柄 / 脏 ----------

(define (session-mark-saved s did)
  (session-set-doc-catalog
   s (doc-state-set-saved (session-doc-catalog s) did (editor-document-handle (session-ed s) did))))

(define (session-dirty? s did)
  (define saved (doc-state-saved (session-doc-catalog s) did))
  (and saved (not (eq? (editor-document-handle (session-ed s) did) saved))))

;;; ---------- 内核适配 ----------

(define (session-ed-close-view s vid)
  (struct-copy session s [ed (editor-close-view (session-ed s) vid)]))
(define (session-ed-close-document s did)
  (struct-copy session s [ed (editor-close-document (session-ed s) did)]))

(define (session-ed-assign! s vid doc)
  (editor-view-assign! (session-ed s) vid doc) s)
(define (session-ed-set-point! s vid line col)
  (editor-view-set-point! (session-ed s) vid (point line col)) s)
(define (session-ed-screen->point s vid row col)
  (editor-view-screen-position->point (session-ed s) vid row col))

(define (session-ed-scroll! s vid n) (editor-view-scroll! (session-ed s) vid n) s)
(define (session-ed-hscroll! s vid delta)
  (define cur (editor-view-left-column (session-ed s) vid))
  (editor-view-set-left-column! (session-ed s) vid (max 0 (+ cur delta)))
  s)
(define (session-ed-nav! s vid dir extend?)
  (define ed (session-ed s))
  (case dir
    [(left)  (editor-view-left! ed vid extend?)]
    [(right) (editor-view-right! ed vid extend?)]
    [(up)    (editor-view-up! ed vid extend?)]
    [(down)  (editor-view-down! ed vid extend?)]
    [(home)  (editor-view-home! ed vid extend?)]
    [(end)   (editor-view-end! ed vid extend?)]
    [else (error 'session-ed-nav "未知方向: ~a（left/right/up/down/home/end）" dir)])
  s)

(define (session-ed-select-all! s vid) (editor-view-select-all! (session-ed s) vid) s)
(define (session-ed-copy! s vid) (editor-view-copy! (session-ed s) vid) s)
(define (session-ed-cut! s vid)
  (define-values (changes _ok?) (editor-view-cut! (session-ed s) vid))
  (values s changes))
(define (session-ed-paste! s vid)
  (define-values (changes _ok?) (editor-view-paste! (session-ed s) vid))
  (values s changes))

(define (session-ed-insert! s vid text)
  (define-values (changes _ok?) (editor-view-insert! (session-ed s) vid text))
  (values s changes))
(define (session-ed-delete! s vid)
  (define-values (changes _ok?) (editor-view-delete! (session-ed s) vid))
  (values s changes))
(define (session-ed-backspace! s vid)
  (define-values (changes _ok?) (editor-view-backspace! (session-ed s) vid))
  (values s changes))
(define (session-ed-undo! s vid) (editor-view-undo! (session-ed s) vid) (values s '()))
(define (session-ed-redo! s vid) (editor-view-redo! (session-ed s) vid) (values s '()))

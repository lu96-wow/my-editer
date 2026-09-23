#lang racket

;;; default-editor/status.rkt —— 状态栏：可复用的**派生 document**
;;;
;;; 状态栏是「内容由外部状态算出来的 document」：
;;;   · 在同一个 editor 里新开一个 1 行、#:history? #f 的 document（+ view）；
;;;   · status-refresh 从「被描述的 view（source）」现算文本，只在与当前不同才写；
;;;   · face 是**投影 provider**（派生，不进文档）；
;;;   · 被动：不接收键盘、不可编辑。core 不需要任何改动。
;;;
;;; source 是它描述的 view（默认 open 时的焦点 view）——这样焦点切到文件树时，
;;; 状态栏仍显示主文档，不会串。

(require "../core/editor.rkt"
         "../core/api.rkt"
         "layout.rkt"
         "panel.rkt"
         rackunit)

(provide
 status? status-open status-close
 status-document-id status-view status-source status-message status-segments
 status-set-source status-with-source status-set-message status-refresh
 status-line
 status-provider status-screen status-panel)

;;; ---------- 值 ----------

(struct status (did vid source message segments) #:transparent)
;; did      : did              状态栏自己的 document
;; vid      : vid              状态栏的 view
;; source   : (or/c vid #f)    被描述的 view（#f = 跟随焦点）
;; message  : (or/c string #f) 瞬时消息（右对齐）
;; segments : (listof (list string face))  上次渲染的段（provider 直接回放）

(define status-document-id status-did)
(define status-view status-vid)

;;; ---------- 渲染模型 ----------

(define (seg-face sym) (hash 'face sym))

;; 默认左段：文档名 + 位置 + 选区数 + 模式。
(define (default-left ed vid)
  (cond
    [(not vid) (list (list " ready" (seg-face 'status)))]
    [else
     (define did (editor-view-document-id ed vid))
     (define p (editor-view-point ed vid))
     (define n (length (editor-view-selections ed vid)))
     (list (list (format " ~a" (editor-document-name ed did)) (seg-face 'status-name))
           (list (format "  L~a:C~a" (add1 (point-line p)) (add1 (point-col p))) (seg-face 'status-pos))
           (list (format "  sel:~a" n) (seg-face 'status-sel))
           (list (format "  ~a" (editor-view-mode ed vid)) (seg-face 'status-mode)))]))

(define (segs-width segs)
  (for/sum ([s (in-list segs)]) (string-display-width (car s))))
(define (segs-text segs) (apply string-append (map car segs)))

;; 按显示列把段截到 cols 宽（宽字符按 char-display-width）。
(define (segs-truncate segs cols)
  (cond
    [(<= cols 0) '()]
    [(null? segs) '()]
    [else
     (define s (car segs))
     (define t (car s))
     (define tw (string-display-width t))
     (cond
       [(<= tw cols) (cons s (segs-truncate (cdr segs) (- cols tw)))]
       [else (list (list (substring t 0 (column->index t cols)) (cadr s)))])]))

;; 左段贴左、右段贴右；width = #f 时不补空格（纯内容）。
(define (fit-line lsegs rsegs width)
  (cond
    [(not width) (values (string-append (segs-text lsegs) (segs-text rsegs)) (append lsegs rsegs))]
    [else
     (define w (max 0 width))
     (define lw (segs-width lsegs))
     (cond
       [(>= lw w) (define ls (segs-truncate lsegs w)) (values (segs-text ls) ls)]
       [else
        (define rfit (segs-truncate rsegs (max 0 (- w lw))))
        (define rw (segs-width rfit))
        (define gap (max 0 (- w lw rw)))
        (define pad (if (> gap 0) (list (list (make-string gap #\space) #f)) '()))
        (define all (append lsegs pad rfit))
        (values (segs-text all) all)])]))

;; 纯逻辑：给 editor（+ 被描述的 vid），算一行文本与段。可脱离 shell 单独用。
(define (status-line ed [vid (editor-focus ed)]
                      #:message [message #f]
                      #:width [width #f]
                      #:left [left #f]
                      #:right [right #f])
  (define lsegs (if left (list (list left (seg-face 'status))) (default-left ed vid)))
  (define rsegs (cond [right (list (list right (seg-face 'status-message)))]
                      [message (list (list message (seg-face 'status-message)))]
                      [else '()]))
  (fit-line lsegs rsegs width))

;;; ---------- 生命周期 ----------

(define (status-open ed [height 1] [width 80]
                     #:name [name "*status*"]
                     #:source [source (editor-focus ed)])
  (define-values (ed1 did) (editor-open-document ed "" (max 1 height) (max 1 width)
                                                 #:name name #:focus? #f #:history? #f))
  (define vid (editor-document-view ed1 did))
  (status-refresh ed1 (status did vid source #f '())))

(define (status-close ed s) (editor-close-document ed (status-document-id s)))

;;; ---------- 刷新 / 配置 ----------

;; 重算文本；与当前相同则**完全不写**（不动 tick）。
(define (status-refresh ed s #:left [left #f] #:right [right #f])
  (define vid (or (status-source s) (editor-focus ed)))
  (define width (editor-view-width ed (status-view s)))   ; 状态栏自己的宽（不是被描述 view 的）
  (define-values (text segs) (status-line ed vid #:message (status-message s)
                                          #:width width #:left left #:right right))
  (define did (status-document-id s))
  (define s* (struct-copy status s [segments segs]))
  (cond
    [(string=? (editor-document->string ed did) text) (values ed s*)]
    [else
     (define n (editor-document-line-count ed did))
     (define p-end (point (sub1 n) (editor-document-line-length ed did (sub1 n))))
     (define-values (ed* _r)
       (editor-command-batch ed (change (list (edit-desc (point 0 0) p-end text)) '())
                             #:view (status-view s) #:trusted? #t #:record? #f))
     (values ed* s*)]))

(define (status-set-source ed s vid)
  (status-refresh ed (struct-copy status s [source vid])))

;; 纯设置 source（不写文档）：切换 buffer 时先改 source，再由 shell 统一 sync。
(define (status-with-source s vid) (struct-copy status s [source vid]))

(define (status-set-message ed s message)
  (status-refresh ed (struct-copy status s [message message])))

;;; ---------- 投影 ----------

(define (status-provider _ed s)
  (lambda (_e _did line)
    (if (zero? line)
        ;; 段是按顺序拼接的文本；provider 要的是**字符索引**区间 [start,end)。
        (let loop ([segs (status-segments s)] [i 0] [acc '()])
          (cond [(null? segs) (reverse acc)]
                [else (define t (caar segs))
                      (define j (+ i (string-length t)))
                      (loop (cdr segs) j (cons (list i j (cadar segs)) acc))]))
        '())))

(define (status-screen ed s)
  (editor-view->screen ed (status-view s) (status-provider ed s)))

;;; ---------- 窗格 ----------

;; 状态栏窗格：被动。sync 与 refresh 同价（都是从 source 现算一行文本）。
(define (status-panel s)
  (panel-open 'status s
    #:project (lambda (ed s) (status-screen ed s))
    #:resize (lambda (ed s r)
               (values (editor-view-set-size ed (status-view s)
                                             (max 1 (rect-h r)) (max 1 (rect-w r)))
                       s))
    #:refresh (lambda (ed s) (status-refresh ed s))
    #:sync (lambda (ed s) (status-refresh ed s))))

;;; ---------- 测试 ----------

(module+ test
  (define ed (editor-open "hello"))
  (define-values (ed1 s) (status-open ed 1 40))
  (check-true (status? s))
  (check-equal? (status-document-id s) (editor-view-document-id ed1 (status-view s)))
  (check-equal? (status-source s) 0)
  (define text (editor-document->string ed1 (status-document-id s)))
  (check-true (string-contains? text "L1:C1"))
  (check-true (string-contains? text "*scratch*"))
  ;; 段与文本一致：首段 face = status-name
  (check-equal? (caar (status-segments s)) (substring text 0 (string-length (caar (status-segments s)))))
  (check-equal? (cadar (status-segments s)) (hash 'face 'status-name))
  ;; provider 给的是字符索引区间；只覆盖第 0 行
  (define prov-runs ((status-provider ed1 s) ed1 (status-document-id s) 0))
  (check-equal? (length prov-runs) (length (status-segments s)))
  (check-equal? (map caddr prov-runs) (map cadr (status-segments s)))
  (check-equal? (caar prov-runs) 0)
  (check-equal? (cadr (last prov-runs)) (string-length text))
  (check-equal? ((status-provider ed1 s) ed1 (status-document-id s) 1) '())
  (check-true (screen? (status-screen ed1 s)))
  (check-equal? (screen-height (status-screen ed1 s)) 1)

  ;; 光标移动后文本跟着变
  (define ed2 (editor-set-point ed1 (point 0 3)))
  ;; 注意 source 仍是 view 0（编辑器里只有一个 view）
  (define-values (ed3 s2) (status-refresh ed2 s))
  (check-true (string-contains? (editor-document->string ed3 (status-document-id s2)) "L1:C4"))

  ;; 瞬时消息：右对齐出现在文本里
  (define-values (ed4 s3) (status-set-message ed3 s "saved"))
  (check-true (string-contains? (editor-document->string ed4 (status-document-id s3)) "saved"))
  (check-equal? (status-message s3) "saved")

  ;; 窄宽度：纯逻辑 status-line 按显示列截断
  (define narrow (call-with-values (lambda () (status-line ed4 0 #:width 10)) (lambda (t _segs) t)))
  (check-true (<= (string-display-width narrow) 10))

  ;; source = #f → 跟随焦点（这里焦点 view 0）
  (define s5 (struct-copy status s3 [source #f]))
  (define-values (_ed6 s6) (status-refresh ed4 s5))
  (check-true (string-contains? (editor-document->string ed4 (status-document-id s6)) "L1:C4"))

  (displayln "status.rkt: all tests passed"))

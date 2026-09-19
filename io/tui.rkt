#lang racket

;;; io/tui.rkt —— 用 racket-tui 接一个可运行的终端编辑器
;;;
;;; 这是「后端」示范：core 只产 screen、只收 events，本文件负责
;;;   1. 把 screen（run 序列）画到终端；
;;;   2. 把按键翻译成 core 的编辑操作（edit-*）与导航（window-*）。
;;;
;;; 运行：  racket io/tui.rkt [文件]
;;; 按键：  可打印键/中文 插入   Enter 换行   Backspace/Delete 删除
;;;         ←→↑↓ Home End PgUp PgDn 导航   Ctrl+Z 撤销   Ctrl+Y 重做
;;;         鼠标点击定位   Ctrl+Q / Esc 退出
;;;
;;; 只用 core/api.rkt（原子）+ core/compose/editor.rkt（editor/命令）。

(require "../core/editor.rkt"
         tui
         racket/string
         racket/path)

;;; ---------- face（语义）→ 终端样式 ----------

(define (face-style face)
  (case (hash-ref face 'face #f)
    [(keyword) 'info]
    [(comment) 'green]
    [(string)  'yellow]
    [(error)   'error]
    [else #f]))

;;; ---------- 一个极简高亮（使用方策略）----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

;; 只扫 [fl,ll] 这些行
(define (syntax-segs ed fl ll)
  (append*
   (for/list ([line (in-range fl (add1 ll))])
     (define text (editor-line-ref ed line))
     (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
       (list line (car m) (cdr m) 'keyword)))))

;; 局部重标：只在这几行上清旧写新（key='face）
(define (highlight-range ed fl ll)
  (editor-apply-patches ed (list (patch 'face fl ll (syntax-segs ed fl ll)))))

;; 打开时全量标一遍
(define (rehighlight ed)
  (highlight-range ed 0 (sub1 (editor-line-count ed))))

;; 命令的第二返回值就是 change-report；有变化就按它给的行区间局部重标
(define (apply-report s report)
  (if report
      (highlight-range s (change-report-first-line report) (change-report-last-line report))
      s))

;; 把一帧 screen 变成要写出的字节。
;; 我们把光标移到「屏幕上第 row 行第 col 列」（0-based）——终端 CUP 是 1-based，故 +1。
(define (render-frame s rows cols [name "*scratch*"])
  (define scr (editor->screen s))
  (define parts (list format-cursor-hide format-screen-clear))
  (define (emit! b) (set! parts (cons b parts)))
  (for ([runs (in-vector (screen-row-runs scr))] [row (in-naturals)])
    (for ([r (in-list runs)])
      (emit! (format-cursor-move (add1 row) (add1 (run-col r))))
      (define st (face-style (run-face r)))
      (emit! (if st (format-styled st (run-text r)) (format-content (run-text r))))))
  ;; 状态行（最后一行）
  (define p (editor-point s))
  (define status
    (format " ~a  L~a:C~a  ~a   ^Z undo ^Y redo ^Q quit"
            name
            (add1 (point-line p)) (add1 (point-col p))
            (if (editor-modified? s) "modified" "saved")))
  (emit! (format-cursor-move rows 1))
  (emit! (format-styled 'status-bar
                        (let ([s status])
                          (if (>= (string-length s) cols)
                              (substring s 0 (max 0 cols))
                              (string-append s (make-string (- cols (string-length s)) #\space))))))
  ;; 光标：跟着 core 算出的屏幕坐标
  (define cr (screen-cursor-row scr))
  (define cc (screen-cursor-col scr))
  (if (>= cr 0)
      (begin (emit! (format-cursor-move (add1 cr) (add1 cc))) (emit! format-cursor-show))
      (emit! format-cursor-hide))
  (apply bytes-append (reverse parts)))

;;; ---------- 入口 ----------

(define (run [path #f])
  (with-tui
   (lambda ()
     (enable-mouse!)
     (enable-bracketed-paste!)
     (define-values (rows0 cols0) (get-window-size))
     (define rows (max 2 rows0))
     (define cols (max 1 cols0))
     (define text (if (and path (file-exists? path)) (file->string path) ""))
     (define s0 (editor-open text (max 1 (- rows 1)) cols))
     (define s (rehighlight s0))
     (define running? #t)

     (define (edit-op op)
       (set! s (let-values ([(s* report) (editor-edit s op)]) (apply-report s* report))))
     (define (undo) (set! s (let-values ([(s* report) (editor-undo s)]) (apply-report s* report))))
     (define (redo) (set! s (let-values ([(s* report) (editor-redo s)]) (apply-report s* report))))
     (define (resize-editor! nr nc)
       (set! rows (max 2 nr)) (set! cols (max 1 nc))
       (set! s (editor-set-view-size s 0 (sub1 rows) cols)))
     (define name (if path (path->string (file-name-from-path path)) "*scratch*"))
     (define (redraw) (put-bytes (render-frame s rows cols name)))

     (define handler
       (build-input
        #:utf-char (lambda (str) (edit-op (edit-insert str)))
        #:char     (lambda (ch)  (edit-op (edit-insert (string (integer->char ch)))))
        #:enter    (lambda ()    (edit-op (edit-newline)))
        #:backspace (lambda ()   (edit-op (edit-backspace)))
        #:delete   (lambda ()    (edit-op (edit-delete)))
        #:tab      (lambda ()    (edit-op (edit-insert "  ")))
        #:left (lambda () (set! s (editor-left s)))
        #:right (lambda () (set! s (editor-right s)))
        #:up (lambda () (set! s (editor-up s)))
        #:down (lambda () (set! s (editor-down s)))
        #:home (lambda () (set! s (editor-home s)))
        #:end (lambda () (set! s (editor-end s)))
        #:pageup   (lambda ()    (set! s (editor-scroll s (- (editor-height s)))))
        #:pagedown (lambda ()    (set! s (editor-scroll s (editor-height s))))
        #:ctrl     (lambda (ch)
                     (case ch
                       [(#\Z) (undo)]
                       [(#\Y) (redo)]
                       [(#\Q) (set! running? #f)]
                       [else (void)]))
        #:escape   (lambda () (set! running? #f))
        #:paste    (lambda (data) (edit-op (edit-insert (bytes->string/utf-8 data))))
        #:mouse-press (lambda (_button x y _mods)
                        (when (< y (sub1 rows))
                          (define-values (l c) (editor-screen->point s y x))
                          (when l (set! s (editor-set-point s (point l c))))))
        #:mouse-scroll (lambda (dir _x _y _mods)
                         (set! s (editor-scroll s (if (eq? dir 'up) -3 3))))
        #:resize   (lambda (nr nc) (resize-editor! nr nc))))

     (define (step type data mods)
       (handler type data mods)
       (redraw))

     (redraw)
     (loop-input/stop (not running?) step))))

;;; ---------- 测试：不开终端，只验证 screen → bytes ----------

(module+ test
  (require rackunit)
  (define s (rehighlight (editor-open "hello\n(define x 42)\nworld" 3 20)))
  (define frame (render-frame s 4 20))
  (check-true (bytes? frame))
  (check-true (regexp-match? #rx"hello" frame))
  (check-true (regexp-match? #rx"world" frame))
  ;; 局部重标：改掉关键字后旧 face 被清掉（patch 的"清旧写新"）
  (check-equal? (editor-get-property s 1 1 'face) 'keyword)
  (define-values (s2 report) (editor-edit s (edit-splice (point 1 0) (point 1 7) "print  ")))
  (define s3 (apply-report s2 report))
  (check-equal? (editor-get-property s3 1 1 'face) #f)
  (check-equal? (change-report-first-line report) 1)
  (displayln "tui.rkt: render smoke test passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run (and (> (vector-length args) 0) (vector-ref args 0))))

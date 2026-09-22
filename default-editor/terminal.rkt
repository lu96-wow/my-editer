#lang racket

;;; default-editor/terminal.rkt —— 默认终端后端
;;;
;;; 唯一碰终端/文件系统 IO 的地方：把 shell 的 screen 画成字节（带增量重绘），
;;; 把终端事件转成 shell 语义操作。core 与 default-editor 其余部分仍然后端无关。
;;;
;;; 增量：screen-damage 给「需要整行重绘」的行；#f = 整屏（尺寸变）。

(require "shell.rkt"
         "../core/api.rkt"
         ;; racket-tui 也导出 key-event / resize-event / cursor-col 等，与 core 同名；用 core 的。
         (except-in tui key-event key-event? key-event-key struct:key-event
                    resize-event resize-event? resize-event-rows resize-event-cols
                    struct:resize-event cursor-col)
         racket/string)

(provide run-default-editor screen->bytes)

;;; ---------- face → 样式 ----------

(define (face-style face)
  (and (hash? face)
       (case (hash-ref face 'face #f)
         [(keyword) 'info]
         [(comment) 'green]
         [(string) 'yellow]
         [(error) 'error]
         [(read-only) 'error]
         [(cursor) 'cursor]
         [(selection) 'selection]
         [(line-number) 'status-bar]
         [(status) 'status-bar]
         [(status-name) 'status-bar]
         [(status-pos) 'status-bar]
         [(status-sel) 'status-bar]
         [(status-mode) 'status-bar]
         [(status-message) 'warning]
         [(tree-dir) 'info]
         [(tree-file) #f]
         [(tree-current) 'selection]
         [else #f])))

;;; ---------- 绘制辅助（与 io/example.rkt 同套路） ----------

(define (pad-to s n)
  (if (>= (string-length s) n) (substring s 0 n)
      (string-append s (make-string (- n (string-length s)) #\space))))

(define (runs-substring runs a b)
  (define out (open-output-string))
  (for ([r (in-list runs)])
    (define rcol (run-col r))
    (define rtext (run-text r))
    (define rw (string-display-width rtext))
    (define lo (max a rcol))
    (define hi (min b (+ rcol rw)))
    (when (< lo hi)
      (display (substring rtext (column->index rtext (- lo rcol)) (column->index rtext (- hi rcol))) out)))
  (get-output-string out))

(define (cell-text runs col)
  (or (for/first ([r (in-list runs)]
                  #:when (let ([rc (run-col r)])
                           (and (<= rc col) (< col (+ rc (string-display-width (run-text r)))))))
        (string (string-ref (run-text r) (column->index (run-text r) (- col (run-col r))))))
      " "))

;; 清行到行尾：增量重绘时先清本行，旧内容/旧 overlay 才不会残留。
(define erase-eol (string->bytes/utf-8 "\u001b[K"))

(define (emit-row! emit! scr row)
  (define runs (screen-row scr row))
  (for ([r (in-list runs)])
    (emit! (format-cursor-move (add1 row) (add1 (run-col r))))
    (define st (face-style (run-face r)))
    (emit! (if st (format-styled st (run-text r)) (format-content (run-text r)))))
  (for ([g (in-list (screen-selections scr))] #:when (= row (region-row g)))
    (define txt (runs-substring runs (region-start-col g) (region-end-col g)))
    (unless (string=? txt "")
      (emit! (format-cursor-move (add1 row) (add1 (region-start-col g))))
      (emit! (format-styled 'selection txt))))
  (for ([c (in-list (screen-cursors scr))] #:when (= row (cursor-row c)))
    (emit! (format-cursor-move (add1 row) (add1 (cursor-col c))))
    (emit! (format-styled 'cursor (cell-text runs (cursor-col c))))))

;;; ---------- 事件循环 ----------

;; 整屏绘制成字节（测试 / 一次性绘制用）。增量版在 run-default-editor 里。
(define (screen->bytes scr)
  (define parts '())
  (define (emit! b) (set! parts (cons b parts)))
  (emit! format-cursor-hide)
  (emit! format-screen-clear)
  (for ([row (in-range (screen-height scr))]) (emit-row! emit! scr row))
  (emit! format-cursor-hide)
  (apply bytes-append (reverse parts)))

(define (run-default-editor [path #f] #:root [root (current-directory)])
  (with-tui
   (lambda ()
     (enable-bracketed-paste!)
     (define-values (rows0 cols0) (get-window-size))
     (define state (box (shell-open path (max 2 rows0) (max 1 cols0) #:root root)))
     (define last (box #f))
     (define running? (box #t))

     (define (->core-mods m)
       (modifiers (and m (mods-ctrl? m)) (and m (mods-alt? m)) (and m (mods-shift? m)) #f))

     (define (draw!)
       (define scr (shell->screen (unbox state)))
       (define damage (if (unbox last) (screen-damage (unbox last) scr) #f))
       (define parts '())
       (define (emit! b) (set! parts (cons b parts)))
       (emit! format-cursor-hide)
       (cond
         [(not damage)
          (emit! format-screen-clear)
          (for ([row (in-range (screen-height scr))]) (emit-row! emit! scr row))]
         [else
          (for ([row (in-list damage)])
            (emit! (format-cursor-move (add1 row) 1))
            (emit! erase-eol)
            (emit-row! emit! scr row))])
       (emit! format-cursor-hide)
       (put-bytes (apply bytes-append (reverse parts)))
       (set-box! last scr))

     (define (apply! f)
       (define-values (s q) (f (unbox state)))
       (set-box! state s)
       (when q (set-box! running? #f)))
     (define (key! k m) (apply! (lambda (s) (shell-key s k (->core-mods m)))))

     (define handler
       (build-input
        #:text      (lambda (str) (set-box! state (shell-text (unbox state) str)))
        #:enter     (lambda () (key! 'enter #f))
        #:backspace (lambda () (key! 'backspace #f))
        #:delete    (lambda () (key! 'delete #f))
        #:tab       (lambda () (key! 'tab #f))
        #:left      (lambda () (key! 'left #f))
        #:right     (lambda () (key! 'right #f))
        #:up        (lambda () (key! 'up #f))
        #:down      (lambda () (key! 'down #f))
        #:home      (lambda () (key! 'home #f))
        #:end       (lambda () (key! 'end #f))
        #:pageup    (lambda () (key! 'pageup #f))
        #:pagedown  (lambda () (key! 'pagedown #f))
        #:escape    (lambda () (key! 'escape #f))
        #:key       (lambda (k m) (key! k m))
        #:resize    (lambda (rows cols)
                      (set-box! state (shell-resize (unbox state) (max 2 rows) (max 1 cols))))))

     (define (step ev) (handler ev) (draw!))
     (draw!)
     (loop-input/stop (not (unbox running?)) step))))

(module+ test
  (require rackunit racket/path)
  (define dir (make-temporary-file "edterm~a" 'directory))
  (call-with-output-file (build-path dir "a.txt") #:exists 'replace (lambda (o) (display "hi" o)))
  (define s (shell-open #f 8 40 #:root dir))
  (define b (screen->bytes (shell->screen s)))
  (check-true (bytes? b))
  (check-true (> (bytes-length b) 0))
  (check-true (regexp-match? #rx"scratch" (bytes->string/utf-8 b)))   ; 状态栏在主文档名
  (delete-directory/files dir)
  (displayln "terminal.rkt: all tests passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run-default-editor (and (> (vector-length args) 0) (vector-ref args 0))))

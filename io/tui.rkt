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
         "editor-ui.rkt"
         ;; tui 也导出 key-event/resize-event 等事件结构体，与 core 同名；
         ;; 这里用 core 的，排除 tui 的。
         (except-in tui key-event key-event? key-event-key struct:key-event
                    resize-event resize-event? resize-event-rows resize-event-cols
                    struct:resize-event)
         racket/string
         racket/path)

;; face / 高亮 / 命令封装 / Ctrl 映射 / 画帧原语都在 io/editor-ui.rkt。

;; 把一帧 screen 变成要写出的字节。
;; 我们把光标移到「屏幕上第 row 行第 col 列」（0-based）——终端 CUP 是 1-based，故 +1。
(define (render-frame s rows cols [name "*scratch*"])
  (define scr (editor->screen s))
  (define parts (list format-cursor-hide format-screen-clear))
  (define (emit! b) (set! parts (cons b parts)))
  (draw-runs! emit! scr)
  ;; 状态行（最后一行）
  (define p (editor-point s))
  (define status
    (format " ~a  L~a:C~a   ^Z undo ^Y redo ^Q quit"
            name
            (add1 (point-line p)) (add1 (point-col p))))
  (emit! (format-cursor-move rows 1))
  (emit! (format-styled 'status-bar
                        (let ([s status])
                          (if (>= (string-length s) cols)
                              (substring s 0 (max 0 cols))
                              (string-append s (make-string (- cols (string-length s)) #\space))))))
  (draw-cursor! emit! scr)
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

     (define (edit-op op) (define-values (s* _) (edit-step s op)) (set! s s*))
     (define (undo) (define-values (s* _) (undo-step s)) (set! s s*))
     (define (redo) (define-values (s* _) (redo-step s)) (set! s s*))
     (define (resize-editor! nr nc)
       (set! rows (max 2 nr)) (set! cols (max 1 nc))
       (set! s (editor-view-set-size s 0 (sub1 rows) cols)))
     (define name (if path (path->string (file-name-from-path path)) "*scratch*"))
     (define (redraw) (put-bytes (render-frame s rows cols name)))

     (define handler
       (build-input
        ;; 新 API：文本统一走 #:text（可打印字符 + 粘贴），收 string
        #:text     (lambda (str) (edit-op (edit-insert str)))
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
        ;; Ctrl 组合走 #:key（key + mods）；无修饰的字符已由 #:text 接走
        #:key      (lambda (key mods)
                     (case (ctrl-action key mods)
                       [(undo) (undo)]
                       [(redo) (redo)]
                       [(quit) (set! running? #f)]
                       [else (void)]))
        #:escape   (lambda () (set! running? #f))
        #:mouse    (lambda (action button x y _mods)
                     (case action
                       [(press)
                        (when (< y (sub1 rows))
                          (define-values (l c) (editor-screen->point s y x))
                          (when l (set! s (editor-goto s (point l c)))))]
                       [(scroll)
                        (set! s (editor-scroll s (if (eq? button 'up) -3 3)))]
                       [else (void)]))
        #:resize   (lambda (nr nc) (resize-editor! nr nc))))

     (define (step ev)
       (handler ev)
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
  (check-equal? (editor-get-property s (editor-focused-buffer-id s) (point 1 1) 'face) 'keyword)
  (define-values (s2 report) (editor-edit s (edit-splice (point 1 0) (point 1 7) "print  ")))
  (define s3 (apply-report s2 report))
  (check-equal? (editor-get-property s3 (editor-focused-buffer-id s3) (point 1 1) 'face) #f)
  (check-equal? (change-report-first-line report) 1)
  (displayln "tui.rkt: render smoke test passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run (and (> (vector-length args) 0) (vector-ref args 0))))

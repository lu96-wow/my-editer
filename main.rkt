#lang racket

(require "core/api.rkt" "io/tui.rkt")

;;; main.rkt —— 两个 window 的最简编辑器（左/右分屏 + 状态行）
;;;
;;; 这层是「组装层」：core 只给 window/buffer/screen/events 原子，
;;; 怎么摆两个窗口、怎么路由输入、怎么拼屏，全在这里自己写。
;;;
;;;   布局：左窗 + 右窗 + 底部状态行（这就是删掉的 layout 的职责，现在手动做）
;;;   输入：racket-tui raw → core event → handle → 哪个窗口的哪个原语
;;;   渲染：两个 window->screen → screen-compose → 一张大屏 → ANSI
;;;
;;; 运行：racket main.rkt（需要真实 Linux 终端）
;;; 按键：Tab / Ctrl+O 切窗口；Ctrl+Q 退出；打字/退格/回车/方向键

;;; ---------- 应用状态：两个 window + 哪个是 active ----------

(struct app (w0 w1 active) #:transparent)

(define (active-window a)
  (if (zero? (app-active a)) (app-w0 a) (app-w1 a)))

(define (update-active a w)
  (if (zero? (app-active a))
      (struct-copy app a [w0 w])
      (struct-copy app a [w1 w])))

(define (switch-active a)
  (struct-copy app a [active (- 1 (app-active a))]))

;;; ---------- 示例内容（两个不同 buffer）---------
;;; 左窗口：minibuffer 式 —— “❯ ” 是 read-only 提示，后面是可编辑输入

(define sample-left
  (string-join
   '("❯ 输入区 hello 你好"
     "(define (square x) (* x x))"
     "(define msg \"hello 😀\") ; 字符串"
     ""
     ";; ↑ 上面那行最前面的 ❯ 是 read-only，试试在上面打字")
   "\n"))

(define sample-right
  (string-join
   '("#lang racket"
     ";; 右窗口 —— Tab / Ctrl+O 切窗口"
     "(define (double x) (* 2 x))"
     "(define msg \"world 😀\")"
     ""
     "(cond [(> x 0) 'pos] [else 'neg])")
   "\n"))

;;; ---------- 一次性语法高亮（属性写进 buffer，之后自动流进 screen）----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")
(define string-rx  #px"\"[^\"]*\"")
(define comment-rx #px";[^\n]*")

(define (matches->segs line rx face text)
  (for/list ([m (in-list (regexp-match-positions* rx text))])
    (list line (car m) (cdr m) 'face face)))

(define (highlight b)
  (buffer-put-properties-many
   b
   (apply append
          (for/list ([line (in-range (buffer-line-count b))])
            (define text (buffer-line-ref b line))
            (append (matches->segs line keyword-rx 'keyword text)
                    (matches->segs line string-rx  'string  text)
                    (matches->segs line comment-rx 'comment text))))))

;; 把左窗第 0 行的 "❯ "（[0,2)）标成 read-only 提示（不可编辑 + 提示色）
(define (prompt-left b)
  (buffer-put-properties-many b
    (list (list 0 0 2 'read-only #t)
          (list 0 0 2 'face 'prompt))))

;;; ---------- 主题（face → 中性样式，后端翻译）----------

(define theme
  (hash 'keyword '(97 175 239)    ; 蓝
        'string  '(152 195 121)   ; 绿
        'comment '(128 128 128)   ; 灰
        'prompt  '(229 192 123)   ; 黄（read-only 提示）
        'mode    '(92 99 112)))   ; 灰（状态行）

;;; ---------- 布局：左右分屏 + 状态行 ----------

;; 左右两窗各占一半宽度，末行留给状态栏
(define (split-size rows cols)
  (define area-h (max 1 (- rows 1)))
  (define left-w (max 1 (quotient cols 2)))
  (define right-w (max 1 (- cols left-w)))
  (values area-h left-w right-w))

(define (make-app rows cols)
  (define-values (area-h left-w right-w) (split-size rows cols))
  ;; 左窗：提示标 read-only，光标放在提示后的输入区（col 2）
  (define w-left
    (window-set-point
     (window-open (prompt-left (highlight (buffer-open sample-left))) area-h left-w)
     (point 0 2)))
  (app w-left
       (window-open (highlight (buffer-open sample-right)) area-h right-w)
       0))

(define (resize-app a rows cols)
  (define-values (area-h left-w right-w) (split-size rows cols))
  (app (window-set-size (app-w0 a) area-h left-w)
       (window-set-size (app-w1 a) area-h right-w)
       (app-active a)))

(define (status-screen a cols)
  (define w (active-window a))
  (define p (window-point w))
  (define text (format "窗口 ~a | Ln ~a, Col ~a | Tab/Ctrl+O 切窗 | Ctrl+Q 退出"
                       (if (zero? (app-active a)) 1 2)
                       (add1 (point-line p))
                       (add1 (point-col p))))
  (define shown (substring text 0 (min (string-length text) cols)))
  (screen 1 cols (vector (list (run 0 shown (hash 'face 'mode)))) -1 -1))

;;; ---------- 渲染：两个 window->screen → compose 成一张大屏 ----------

(define (render a)
  (define w0 (app-w0 a))
  (define w1 (app-w1 a))
  (define area-h (window-height w0))
  (define left-w (window-width w0))
  (define total-w (+ left-w (window-width w1)))
  (screen-compose
   (+ area-h 1) total-w
   (list (list 'left   0      0    (window->screen w0))
         (list 'right  left-w 0    (window->screen w1))
         (list 'status 0      area-h (status-screen a total-w)))
   (if (zero? (app-active a)) 'left 'right)))   ; 光标来自 active 窗口

;;; ---------- 命令层：event → 哪个窗口的哪个原语 ----------

;; 导航（单值返回）
(define (on-nav a thunk)
  (update-active a (window-ensure-point (thunk (active-window a)))))

;; 编辑（返回 (values window desc)，desc 丢给上层，这里先不用）
(define (on-edit a thunk)
  (define-values (w _) (thunk (active-window a)))
  (update-active a (window-ensure-point w)))

(define (handle a ev)
  (cond
    [(quit-event? ev) (values a #t)]
    [(text-event? ev)
     (values (on-edit a (λ (w) (window-insert-string w (text-event-text ev)))) #f)]
    [(key-event? ev)
     (define k (key-event-key ev))
     (define mods (key-event-modifiers ev))
     (cond
       ;; 字符键 = Ctrl+字符（普通字符走 text-event）
       [(char? k)
        (cond
          [(and (modifiers-control mods) (char-ci=? k #\q)) (values a #t)]
          [(and (modifiers-control mods) (char-ci=? k #\o)) (values (switch-active a) #f)]
          [else (values a #f)])]
       [else
        (case k
          [(tab)       (values (switch-active a) #f)]
          [(enter)     (values (on-edit a window-newline) #f)]
          [(backspace) (values (on-edit a window-backspace) #f)]
          [(delete)    (values (on-edit a window-delete) #f)]
          [(left)      (values (on-nav a window-left) #f)]
          [(right)     (values (on-nav a window-right) #f)]
          [(up)        (values (on-nav a (λ (w) (window-visual-move w -1))) #f)]
          [(down)      (values (on-nav a (λ (w) (window-visual-move w +1))) #f)]
          [(home)      (values (on-nav a window-home) #f)]
          [(end)       (values (on-nav a window-end) #f)]
          [else        (values a #f)])])]
    [(resize-event? ev)
     (values (resize-app a (resize-event-rows ev) (resize-event-cols ev)) #f)]
    [else (values a #f)]))

;;; ---------- 启动 ----------

(module+ main
  (displayln "左窗 ❯ 是 read-only 提示；Tab/Ctrl+O 切窗 | Ctrl+Q 退出")
  (tui-run theme make-app render handle))

;;; ---------- 测试（纯函数，不碰终端）----------

(module+ test
  (require rackunit)

  (define a (make-app 10 40))

  ;; 布局：左右各 20 列，高 9（10-1 状态行）
  (check-equal? (window-width (app-w0 a)) 20)
  (check-equal? (window-width (app-w1 a)) 20)
  (check-equal? (window-height (app-w0 a)) 9)

  ;; 渲染：buffer 区 + 状态行 = 10 行，40 列
  (define s (render a))
  (check-equal? (screen-rows s) 10)
  (check-equal? (screen-cols s) 40)

  ;; 左窗提示区 read-only：光标在提示后 col 2，提示本身不可编辑
  (check-equal? (window-point (app-w0 a)) (point 0 2))
  (check-equal? (buffer-get-property (window-buffer (app-w0 a)) 0 1 'read-only) #t)
  (check-equal? (buffer-get-property (window-buffer (app-w0 a)) 0 1 'face) 'prompt)

  ;; 输入路由：text 打到 active 窗口（默认左窗，光标在提示后）
  (define-values (a2 _1) (handle a (text-event "X" (modifiers #f #f #f #f))))
  (check-equal? (buffer-line-ref (window-buffer (app-w0 a2)) 0) "❯ X输入区 hello 你好")
  (check-equal? (buffer-line-ref (window-buffer (app-w1 a2)) 0) "#lang racket")  ; 右窗不动

  ;; Tab 切窗后，text 打到右窗
  (define-values (a3 _2) (handle a2 (key-event 'tab (modifiers #f #f #f #f))))
  (check-equal? (app-active a3) 1)
  (define-values (a4 _3) (handle a3 (text-event "Y" (modifiers #f #f #f #f))))
  (check-equal? (buffer-line-ref (window-buffer (app-w1 a4)) 0) "Y#lang racket")

  ;; 光标来自 active 窗口：切到右窗后，屏幕光标应落在右半（x ≥ 20）
  (define s4 (render a4))
  (check-true (>= (screen-cursor-col s4) 20))

  ;; Ctrl+Q → done
  (define-values (_w done?) (handle a (key-event #\q (modifiers #t #f #f #f))))
  (check-true done?)

  (displayln "main.rkt: all tests passed"))

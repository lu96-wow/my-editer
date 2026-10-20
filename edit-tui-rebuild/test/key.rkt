#lang racket

;;; 键 token（标签 + 原始字节）测试。
;;;
;;; 重点：中间状态就是 (tag . bytes) —— 绑定和事件用同一种表示，
;;; 终端不能区分的组合共用 token（C-i = Tab …），不会有死绑定。

(require rackunit
         "../main.rkt")

;;; ---------- 编码：绑定 -> (tag . bytes) ----------
(check-equal? (key 'a) (key-token 'key #"a"))
(check-equal? (key 'A) (key-token 'key #"A"))          ; 大小写保留
(check-equal? (key 'space) (key-token 'key #" "))
(check-equal? (key #\中) (key-token 'utf8 (string->bytes/utf-8 "中")))
(check-equal? (key 'enter) (key-token 'key #"\r"))
(check-equal? (key 'tab) (key-token 'key #"\t"))
(check-equal? (key 'backspace) (key-token 'key #"\x7f"))
(check-equal? (key 'escape) (key-token 'key #"\e"))

;; Ctrl / Alt
(check-equal? (key 'a 'ctrl) (key-token 'ctrl #"\x01"))
(check-equal? (key 'z 'ctrl) (key-token 'ctrl #"\x1a"))
(check-equal? (key 'a 'alt) (key-token 'alt #"\ea"))
(check-equal? (key 'a 'ctrl 'alt) (key-token 'mod-seq #"\e\x01"))

;; 命名键：规范 CSI 写法；修饰键走 CSI 参数
(check-equal? (key 'left) (key-token 'left #"\e[D"))
(check-equal? (key 'up) (key-token 'up #"\e[A"))
(check-equal? (key 'delete) (key-token 'del #"\e[3~"))   ; delete 别名
(check-equal? (key 'left 'shift) (key-token 'mod-seq #"\e[1;2D"))
(check-equal? (key 'left 'ctrl) (key-token 'mod-seq #"\e[1;5D"))
(check-equal? (key 'pageup 'ctrl) (key-token 'mod-seq #"\e[5;5~"))
(check-equal? (key 'tab 'shift) (key-token 'backtab #"\e[Z"))

;;; ---------- 终端不能区分的组合 = 同一个 token ----------
(check-equal? (key 'i 'ctrl) (key 'tab))        ; C-i 就是 Tab
(check-equal? (key 'h 'ctrl) (key 'backspace))  ; C-h 就是 Backspace
(check-equal? (key 'm 'ctrl) (key 'enter))      ; C-m 就是 Enter
(check-equal? (key 'j 'ctrl) (key 'enter))      ; LF 归一成 CR
(check-true (equal? (key 'j 'ctrl) (key-token 'key #"\r")))
(check-equal? (key 'space 'ctrl) (key-token 'key #"\x00"))  ; C-Space = NUL
(check-equal? (key 'A 'shift) (key 'A))         ; shift 对字符键无编码意义

;;; ---------- raw -> token：命名键写法归一 ----------
(define (raw tag bs) (raw-key-token tag bs))
(check-equal? (raw 'up #"\eOA") (key 'up))      ; SS3 应用光标模式
(check-equal? (raw 'up #"\e[A") (key 'up))      ; CSI
(check-equal? (raw 'home #"\e[1~") (key 'home)) ; 老式 Home
(check-equal? (raw 'home #"\e[7~") (key 'home))
(check-equal? (raw 'end #"\e[4~") (key 'end))
(check-equal? (raw 'insert #"\e[2~") (key 'insert))
(check-equal? (raw 'pageup #"\e[5~") (key 'pageup))
;; 普通字节原样保留（含 canonical 归一：BS -> DEL、LF -> CR）
(check-equal? (raw 'key #"\x08") (key 'backspace))
(check-equal? (raw 'key #"\x0a") (key 'enter))
(check-equal? (raw 'key #"\x09") (key 'tab))
(check-equal? (raw 'key #"\x1b") (key 'escape))
(check-equal? (raw 'ctrl #"\x17") (key 'w 'ctrl))
(check-equal? (raw 'utf8 (string->bytes/utf-8 "中")) (key #\中))
(check-equal? (raw 'mod-seq #"\e[1;2A") (key 'up 'shift))

;;; ---------- 可打印文本 ----------
(check-equal? (key-text (key 'a)) "a")
(check-equal? (key-text (key 'A)) "A")
(check-equal? (key-text (key 'space)) " ")
(check-equal? (key-text (key #\中)) "中")
(check-false (key-text (key 'left)))
(check-false (key-text (key 'enter)))
(check-false (key-text (key 'tab)))
(check-false (key-text (key 'backspace)))
(check-false (key-text (key 'a 'ctrl)))
(check-false (key-text (key 'a 'alt)))
(check-false (key-text (key 'space 'ctrl)))

;;; ---------- 显示 ----------
(check-equal? (key->string (key 'a)) "a")
(check-equal? (key->string (key 'space)) "Space")
(check-equal? (key->string (key 'a 'ctrl)) "C-a")
(check-equal? (key->string (key 'a 'alt)) "M-a")
(check-equal? (key->string (key 'left)) "Left")
(check-equal? (key->string (key 'left 'shift)) "S-Left")
(check-equal? (key->string (key 'pageup 'ctrl)) "C-PageUp")
(check-equal? (key->string (key 'escape)) "Escape")
(check-equal? (key->string (key 'backspace)) "Backspace")
(check-equal? (key->string (key #\中)) "中")

;;; ---------- 绑不上 / 未知的键要报错 ----------
(check-exn exn:fail? (λ () (key 'tab 'ctrl)))
(check-exn exn:fail? (λ () (key 'nonsense-name)))

;;; ---------- 命令表：C-i 触发 Tab 的绑定（不再是死绑定） ----------
(define table*
  (keys
   [(key 'tab)    'indent]
   [(key 'enter)  'newline]
   [(key 'a)      'cmd-a]))

(define (lookup table tok)
  (let-values ([(st v) (command-table-lookup table (list tok))])
    (cons st v)))

(check-equal? (lookup table* (key 'i 'ctrl)) (cons 'command 'indent))
(check-equal? (lookup table* (key 'tab)) (cons 'command 'indent))
(check-equal? (lookup table* (key 'enter)) (cons 'command 'newline))
(check-equal? (lookup table* (key 'a)) (cons 'command 'cmd-a))
(check-equal? (lookup table* (key 'b)) (cons 'unbound #f))

;;; ---------- raw 适配：tui (type data mods) -> app 事件 ----------
(define (raw-event type data)
  (tui-event->app type data #f))

(check-equal? (key-event-token (raw-event 'key #"a")) (key 'a))
(check-equal? (key-event-token (raw-event 'ctrl #"")) (key 'w 'ctrl))
(check-equal? (key-event-token (raw-event 'alt #"\ea")) (key 'a 'alt))
(check-equal? (key-event-token (raw-event 'utf8 (string->bytes/utf-8 "中"))) (key #\中))
(check-equal? (key-event-token (raw-event 'up #"\eOA")) (key 'up))
(check-equal? (key-event-token (raw-event 'mod-seq #"\e[1;2A")) (key 'up 'shift))
(check-equal? (key-event-token (raw-event 'home #"\e[1~")) (key 'home))
(check-false (raw-event 'null (bytes)))

;; paste 保留原始字节
(define pe (raw-event 'paste (string->bytes/utf-8 "hello 中")))
(check-true (paste-event? pe))
(check-equal? (paste-event-bytes pe) (string->bytes/utf-8 "hello 中"))

;; resize / mouse
(define re (raw-event 'resize (cons 10 80)))
(check-equal? (list (resize-event-rows re) (resize-event-cols re)) '(10 80))
(define me (raw-event 'mouse (list 'press 'left 3 4 (list #f #f #f))))
; mouse raw 的 x/y 是 1-based：x=3 y=4 -> row 3 col 2
(check-equal? (list (mouse-event-token me) (mouse-event-row me) (mouse-event-col me))
              '(press 3 2))

(displayln "edit-tui-rebuild/test/key.rkt: ok")

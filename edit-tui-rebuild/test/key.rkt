#lang racket

;;; 键 token / 终端可达性测试。
;;;
;;; 重点：C-i 在 ANSI 终端里就是 tab（同一字节 0x09），所以永远到不了
;;; 命令表。这里用 tui 的真实字节分类器复现一遍，防止以后误绑定。

(require rackunit
         (prefix-in t: tui)
         "../main.rkt")

;;; ---------- 字节 -> app 键 token（复刻 runtime/tui-adapter 的转换） ----------

(define (bytes->token b)
  ;; ESC 单独走 read-event-ansi 的 escape 分支（带 ESCDELAY 超时），
  ;; normalize-event 没有 'escape 类型，这里直接补出来。
  (define ev
    (if (= b 27)
        (t:key-event 'escape t:no-mods)
        (t:normalize-event (t:classify-byte b) (bytes b) #f)))
  (define m (t:key-event-mods ev))
  (define mods (for/list ([s (in-list '(ctrl alt shift))]
                          [on? (in-list (list (t:mods-ctrl? m)
                                              (t:mods-alt? m)
                                              (t:mods-shift? m)))]
                          #:when on?)
                 s))
  (apply key (t:key-event-key ev) mods))

;;; ---------- 特殊字节被归一成命名键 ----------
(check-equal? (bytes->token 9)  (key 'tab))        ; C-i
(check-equal? (bytes->token 8)  (key 'backspace))  ; C-h
(check-equal? (bytes->token 10) (key 'enter))      ; C-j
(check-equal? (bytes->token 13) (key 'enter))      ; C-m
(check-equal? (bytes->token 27) (key 'escape))     ; C-[
(check-equal? (bytes->token 127) (key 'backspace)) ; C-?

;; 普通 ctrl 字母仍然带 ctrl 位
(check-equal? (bytes->token 5)  (key 'e 'ctrl))    ; C-e
(check-equal? (bytes->token 7)  (key 'g 'ctrl))    ; C-g
(check-equal? (bytes->token 23) (key 'w 'ctrl))    ; C-w

;;; ---------- key-deliverable? ----------

(check-true  (key-deliverable? (key 'e 'ctrl)))
(check-true  (key-deliverable? (key 'w 'ctrl)))
(check-true  (key-deliverable? (key 'tab)))
(check-true  (key-deliverable? (key 'left 'ctrl)))
(check-false (key-deliverable? (key 'i 'ctrl)))
(check-false (key-deliverable? (key 'I 'ctrl)))   ; 大写也按小写判
(check-false (key-deliverable? (key 'h 'ctrl)))
(check-false (key-deliverable? (key 'space 'ctrl)))
(check-false (key-deliverable? (key #\@ 'ctrl)))
(check-false (key-deliverable? (key #\[ 'ctrl)))
(check-false (key-deliverable? (key 'tab 'ctrl)))

;;; ---------- 绑到命令表里：C-i 键永远命中不了 ----------

(define table*
  (keys
   [(key 'i 'ctrl) 'insert-x]
   [(key 'e 'ctrl) 'insert-x-ok]
   [(key 'tab)     'indent]))

(define (lookup table seq)
  (let-values ([(st v) (command-table-lookup table seq)])
    (cons st v)))

;; 用户按 C-i / Tab，收到的都是 (key 'tab)
(check-equal? (lookup table* (list (bytes->token 9))) (cons 'command 'indent))
;; C-i 那条 binding 是死代码：
(check-false (key-deliverable? (key 'i 'ctrl)))
;; 换成 C-e 之后才真的收得到
(check-equal? (lookup table* (list (bytes->token 5))) (cons 'command 'insert-x-ok))

(displayln "edit-tui-rebuild/test/key.rkt: ok")

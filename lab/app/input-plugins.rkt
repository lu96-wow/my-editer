#lang racket

(require "../../core/editor.rkt"
         "../ui/mode.rkt"
         "state.rkt")

;;; lab/app/input-plugins.rkt —— 输入插件（改编辑行为，主进程同步跑）
;;;
;;; 与 plugin/ 的区别：plugin/ 在后台进程里跑、只写属性、**不改文本**；
;;; 输入插件在**每次按键同步**执行，会改编辑，所以留在主进程 app 层。
;;;
;;; 一个插件 = 两个可选钩子；返回 #f = 不插手（交给下一个插件 / 默认行为）：
;;;   on-text      : (app string) -> #f | (listof change)   '() = 插手但不改文本
;;;   on-backspace : (app)        -> #f | (listof change)
;;; 多个插件按注册顺序问，**第一个插手的赢**。钩子自己做编辑并返回 core 的 change，
;;; 由 commands.rkt 统一 note 给属性插件层（保持影子文本同步）。
;;;
;;; 内置：自动配对（auto-pair）。

(provide (struct-out input-plugin) input-plugins
         input-plugins-text! input-plugins-backspace!)

(struct input-plugin (name on-text on-backspace) #:transparent)
;; on-text / on-backspace : 见上；用不到的方向给 #f

(define (input-plugins-text! a text)
  (for/or ([p (in-list input-plugins)])
    (define h (input-plugin-on-text p))
    (and h (h a text))))

(define (input-plugins-backspace! a)
  (for/or ([p (in-list input-plugins)])
    (define h (input-plugin-on-backspace p))
    (and h (h a))))

;;; ================= 内置插件：自动配对 =================
;;;
;;; 输入开括号 ( [ { < → 自动补对应闭括号，光标停中间；
;;; 输入闭括号且右边就是同一个 → 跳过（不重复插入）。
;;; 有选区 / 在 prompt 里 / 只读 → 不插手。

(define open->close (hash #\( #\) #\[ #\] #\{ #\} #\< #\>))
(define closer? (hash #\) #t #\] #t #\} #t #\> #t))

(define (auto-pair-text a text)
  (define vid (app-focus a))
  (define ed (app-ed a))
  (cond
    [(or (not vid) (prompt? (app-mode a))) #f]
    [(not (= 1 (string-length text))) #f]
    [(not (selection-empty? (editor-view-primary ed vid))) #f]
    [else
     (define ch (string-ref text 0))
     (define line (editor-view-point-line ed vid))
     (define col (editor-view-point-column ed vid))
     (cond
       ;; 开括号：插入「开+闭」，光标回中间
       [(hash-has-key? open->close ch)
        (define-values (changes _ok?)
          (editor-view-insert! ed vid (string ch (hash-ref open->close ch))))
        (cond [(null? changes) #f]                       ; 只读挡 → 不插手
              [else (editor-view-left! ed vid) changes])]
       ;; 闭括号且右边同字符：跳过
       [(and (hash-has-key? closer? ch)
             (eqv? ch (editor-view-char-at ed vid line col)))
        (editor-view-right! ed vid)
        '()]
       [else #f])]))

(define auto-pair-plugin
  (input-plugin 'auto-pair auto-pair-text #f))

(define input-plugins (list auto-pair-plugin))

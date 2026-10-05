#lang racket

(require "../../../core/editor.rkt"
         "../../core/state.rkt"
         "../../ui/mode.rkt"
         "api.rkt")

;;; lab-rebuild/plugin/input/auto-pair.rkt —— 自动配对（内置输入插件）
;;;
;;; 输入开括号 ( [ { < → 自动补对应闭括号，光标停中间；
;;; 输入闭括号且右边就是同一个 → 跳过（不重复插入）。
;;; 有选区 / 在 prompt 里 / 只读 → 不插手。

(provide auto-pair-plugin)

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

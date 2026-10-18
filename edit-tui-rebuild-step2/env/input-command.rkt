#lang racket

;;; env/input-command.rkt —— 输入栏字符串匹配 + 处理（纯值）
;;; layer  : env
;;; effect : 无（纯值 + 纯匹配）

;;; 输入栏是 *input* document，buffer 内容 = prompt 前缀 + 用户输入。
;;; 提交时拿**完整字符串**，按顺序匹配 input-command：
;;;
;;;   match   : string -> any/c | #f
;;;   handler : ctx value -> transition
;;;   cancel  : #f | (state -> state)   被新 input 替换时清理外部状态
;;;
;;; 这样输入栏不需要 state 里的 prompt 状态机；prompt/答案都在 buffer 里。

(provide (struct-out input-command)
         make-input-command
         input-command-prefix
         input-command-regexp
         input-command-list)

(struct input-command (name match handler cancel) #:transparent)
;; name    : symbol
;; match   : string -> any/c | #f
;; handler : ctx value -> transition
;; cancel  : #f | (state -> state)

(define (make-input-command name match handler #:cancel [cancel #f])
  (input-command name match handler cancel))

;; 固定前缀匹配：返回前缀之后的字符串。
(define (input-command-prefix prefix)
  (λ (text)
    (and (string? text)
         (>= (string-length text) (string-length prefix))
         (string=? prefix (substring text 0 (string-length prefix)))
         (substring text (string-length prefix)))))

;; 正则匹配：返回 regexp-match 的结果（listof string/bytes）或 #f。
(define (input-command-regexp rx)
  (λ (text)
    (and (string? text) (regexp-match rx text))))

;; 在注册表里按顺序找第一条匹配。
(define (input-command-list commands text)
  (for/or ([c (in-list commands)])
    (define v ((input-command-match c) text))
    (and v (cons c v))))

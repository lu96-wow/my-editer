#lang racket

;;; model/input.rkt —— 输入状态（纯数据）
;;; layer  : model
;;; effect : 无（纯数据）

;;; 输入栏的 prompt/输入文本不在这里：它是 *input* document 的 buffer。
;;; 这里只保留与“按键序列 / 模态 / 手势 / 输入会话身份”有关的状态。
;;;
;;; 约定：切焦点不再自动清 pending；是否取消由命令 / 模式策略决定。

(provide (struct-out gesture)
         (struct-out input-session)
         (struct-out input)
         make-gesture idle-gesture?
         make-input-session
         make-input
         input-empty
         input-pending? input-clear-pending input-set-pending
         input-push-mode input-pop-mode input-modes
         input-set-gesture input-set-session)

(struct gesture (kind owner data) #:transparent)
;; kind  : 'seam | 'select | …
;; owner : view-id | region-id | #f
;; data  : any/c

(define (idle-gesture? g) (not (gesture? g)))
(define (make-gesture kind owner data) (gesture kind owner data))

;; 输入会话身份：谁占用了 *input* document，以及替换 / 取消时该清理什么。
;;   tag    : symbol             owner 名（'open-file / 'save-as / 'save-confirm …）
;;   data   : any/c              该会话的参数（例如 doc-id / 目录）
;;   cancel : (state -> state) | #f
;;   prompt : string             便于调试；真正的 prompt 在 input buffer 里
;;
;; 有了 session，替换 input 时不需要再用 prompt 正则反查 owner。
(struct input-session (tag data cancel prompt) #:transparent)

(define (make-input-session tag data cancel prompt)
  (unless (symbol? tag)
    (error 'make-input-session "tag 要是 symbol：~a" tag))
  (unless (or (not cancel) (procedure? cancel))
    (error 'make-input-session "cancel 要是过程或 #f：~a" cancel))
  (unless (string? prompt)
    (error 'make-input-session "prompt 要是 string：~a" prompt))
  (input-session tag data cancel prompt))

(struct input (pending modes gesture session-info) #:transparent)
;; pending : (listof token)
;; modes   : (listof symbol)  临时模态名
;; gesture : gesture | #f
;; session-info : input-session | #f  当前输入栏的占用者

(define (input-empty) (input '() '() #f #f))

(define (make-input #:pending [pending '()]
                    #:modes [modes '()]
                    #:gesture [gesture #f]
                    #:session [session-info #f])
  (input pending modes gesture session-info))

(define (input-pending? i) (pair? (input-pending i)))
(define (input-clear-pending i) (struct-copy input i [pending '()]))
(define (input-set-pending i p) (struct-copy input i [pending p]))
(define (input-push-mode i m) (struct-copy input i [modes (cons m (input-modes i))]))
(define (input-pop-mode i)
  (define ms (input-modes i))
  (struct-copy input i [modes (if (null? ms) '() (cdr ms))]))
(define (input-set-gesture i g) (struct-copy input i [gesture g]))
(define (input-set-session i session-info) (struct-copy input i [session-info session-info]))

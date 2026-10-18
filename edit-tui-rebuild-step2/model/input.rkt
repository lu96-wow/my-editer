#lang racket

;;; model/input.rkt —— 输入状态（纯数据）
;;; layer  : model
;;; effect : 无（纯数据）

;;; 输入栏的 prompt/输入文本不在这里：它是 *input* document 的 buffer。
;;; 这里只保留与“按键序列 / 模态 / 手势”有关的状态。
;;;
;;; 约定：切焦点不再自动清 pending；是否取消由命令 / 模式策略决定。

(provide (struct-out gesture)
         (struct-out input)
         make-gesture idle-gesture?
         make-input
         input-empty
         input-pending? input-clear-pending input-set-pending
         input-push-mode input-pop-mode input-modes
         input-set-gesture)

(struct gesture (kind owner data) #:transparent)
;; kind  : 'seam | 'select | …
;; owner : view-id | region-id | #f
;; data  : any/c

(define (idle-gesture? g) (not (gesture? g)))
(define (make-gesture kind owner data) (gesture kind owner data))

(struct input (pending modes gesture) #:transparent)
;; pending : (listof token)
;; modes   : (listof symbol)  临时模态名
;; gesture : gesture | #f

(define (input-empty) (input '() '() #f))

(define (make-input #:pending [pending '()]
                    #:modes [modes '()]
                    #:gesture [gesture #f])
  (input pending modes gesture))

(define (input-pending? i) (pair? (input-pending i)))
(define (input-clear-pending i) (struct-copy input i [pending '()]))
(define (input-set-pending i p) (struct-copy input i [pending p]))
(define (input-push-mode i m) (struct-copy input i [modes (cons m (input-modes i))]))
(define (input-pop-mode i)
  (define ms (input-modes i))
  (struct-copy input i [modes (if (null? ms) '() (cdr ms))]))
(define (input-set-gesture i g) (struct-copy input i [gesture g]))

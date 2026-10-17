#lang racket

;;; model/input.rkt —— 输入状态（纯数据）
;;;
;;; 输入状态从 world 里独立出来，因为它有**自己的生命周期**：
;;;   · pending  : 已按下的键序列（prefix）；
;;;   · modes    : 临时模态层栈（overlay / prompt / which-key …）；
;;;   · gesture  : 鼠标手势（拖缝 / 拖选 …）；
;;;   · prompt   : 命令输入会话（minibuffer）。
;;;
;;; 约定：切焦点**不再自动清 pending**；是否取消由命令 / 模式策略决定。
;;; 这样状态栏滚动、prompt、overlay 都不会被焦点切换意外打断。

(provide (struct-out gesture)
         (struct-out prompt)
         (struct-out input)
         make-gesture idle-gesture?
         make-prompt
         make-input
         input-empty
         input-pending? input-clear-pending input-set-pending
         input-push-mode input-pop-mode input-modes
         input-set-gesture input-set-prompt)

;;; ---------- 手势 ----------

(struct gesture (kind owner data) #:transparent)
;; kind  : 'seam | 'select | …（开放集；具体解释由对应 scope / command 负责）
;; owner : view-id | region-id | #f   手势主体（拖动中决定用哪张表）
;; data  : any/c                     手势私有数据

(define (idle-gesture? g) (not (gesture? g)))
(define (make-gesture kind owner data) (gesture kind owner data))

;;; ---------- prompt（命令输入会话） ----------

(struct prompt (kind label text source handler) #:transparent)
;; kind    : 'string | 'key | 'key-seq | 'number | 'choice | 'any
;; label   : string     提示语（投影层显示在 text 前）
;; text    : string     当前已输入值（不含 label 前缀）
;; source  : region-id | #f   输入显示在哪个区域
;; handler : any/c      提交时交给谁（command-id / 过程；后续块定）
;;
;; prompt 的“显示文本 = prompt 前缀 + text”由投影层根据 kind/source 计算，
;; 不靠写一个特殊 buffer。

(define (make-prompt kind
                     #:label [label ""]
                     #:text [text ""]
                     #:source [source #f]
                     #:handler [handler #f])
  (prompt kind label text source handler))

;;; ---------- input ----------

(struct input (pending modes gesture prompt-session) #:transparent)
;; pending : (listof token)     已按下的键序列
;; modes   : (listof symbol)    临时模态栈（栈顶在前）
;; gesture : gesture | #f
;; prompt-session : prompt | #f

(define (input-empty)
  (input '() '() #f #f))

(define (make-input #:pending [pending '()]
                    #:modes [modes '()]
                    #:gesture [gesture #f]
                    #:prompt [prompt #f])
  (input pending modes gesture prompt))

(define (input-pending? i) (pair? (input-pending i)))
(define (input-clear-pending i) (struct-copy input i [pending '()]))
(define (input-set-pending i p) (struct-copy input i [pending p]))

(define (input-push-mode i m) (struct-copy input i [modes (cons m (input-modes i))]))
(define (input-pop-mode i)
  (define ms (input-modes i))
  (struct-copy input i [modes (if (null? ms) '() (cdr ms))]))

(define (input-set-gesture i g) (struct-copy input i [gesture g]))
(define (input-set-prompt i p) (struct-copy input i [prompt-session p]))

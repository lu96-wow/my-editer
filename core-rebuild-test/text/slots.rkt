#lang racket

;;; 槽容器测试 —— 注册 / 命名访问器 / fork 策略 / 冻结
;;; 与 core-rebuild/text/{slots,slot-dsl,document}.rkt 对应。

(require rackunit
         "../../core-rebuild/text/document.rkt"
         "../../core-rebuild/text/slot-dsl.rkt"
         "../../core-rebuild/text/slots.rkt"
         "../../core-rebuild/text/base/track.rkt"
         "../../core-rebuild/text/base/line.rkt")

;;; ---------- 设计时声明槽（必须在任何 document 创建前） ----------

(define-document-slot meta-a #:default 'none #:fork reset)

;; transform：用 fork-ctx 的 changes 计数
(define (count-transform old ctx)
  (+ old (length (fork-ctx-changes ctx))))
(define-document-slot nchanges #:default 0 #:fork (transform count-transform))

;; transform：用 fork-ctx 的新文本长度（字符数）
(define (len-transform _old ctx)
  (string-length (lines->string (track->list (fork-ctx-new-text ctx)))))
(define-document-slot tlen #:default 0 #:fork (transform len-transform))

;;; ---------- 初始：默认值 ----------

(define d0 (document-open "abc"))
(check-equal? (document-slot-meta-a d0) 'none)
(check-equal? (document-slot-nchanges d0) 0)
(check-equal? (document-slot-tlen d0) 0)

;; atom 访问器给出 box
(check-true (box? (document-slot-meta-a-atom d0)))

;;; ---------- 写当前版本（就地，不换 document 身份） ----------

(document-set-slot-meta-a! d0 'v1)
(check-equal? (document-slot-meta-a d0) 'v1)

;;; ---------- fork：reset 清空；transform 推进；旧版本不受影响 ----------

(define-values (d1 _ch1 _ok1) (document-insert d0 0 1 "X"))   ; "aXbc"
(check-equal? (document->string d1) "aXbc")
(check-equal? (document-slot-meta-a d1) 'none)     ; reset → 默认
(check-equal? (document-slot-nchanges d1) 1)       ; transform：+1 change
(check-equal? (document-slot-tlen d1) 4)           ; transform：新文本长度

;; 旧版本槽完好（无别名污染）
(check-equal? (document-slot-meta-a d0) 'v1)
(check-equal? (document-slot-nchanges d0) 0)
(check-equal? (document-slot-tlen d0) 0)

;; 再编辑一次：transform 从 d1 的旧值继续
(define-values (d2 _ch2 _ok2) (document-insert d1 0 0 "Y"))   ; "YaXbc"
(check-equal? (document-slot-nchanges d2) 2)
(check-equal? (document-slot-tlen d2) 5)

;;; ---------- 冻结：注册晚于文档创建应报错 ----------

(check-exn exn? (lambda () (register-slot! 'late #f 'reset)))

(displayln "slots.rkt: all tests passed")

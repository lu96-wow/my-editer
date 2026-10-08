#lang racket

;;; 开放槽 API 测试 —— 槽是 opaque 值，按 index 读写；fork 策略；保留名
;;; 与 core-rebuild/editor/{attributes,query}.rkt + text/{slots,slot-dsl}.rkt 对应。

(require rackunit
         "../../core-rebuild/editor.rkt"
         "../../core-rebuild/editor/attributes.rkt"
         "../../core-rebuild/editor/query.rkt"
         "../../core-rebuild/text/slot-dsl.rkt"
         "../../core-rebuild/text/slots.rkt"
         "../../core-rebuild/text/document.rkt")

;;; ---------- 设计时声明槽（必须在建 editor 前） ----------

(define-document-slot marks #:default #f #:fork reset)

;; 值级 transform：每次编辑累加变更数
(define (bump old ctx) (+ old (length (fork-ctx-changes ctx))))
(define-document-slot nchanges #:default 0 #:fork (transform bump))

;;; ---------- 保留名（在冻结前） ----------
(check-exn exn? (lambda () (register-slot! 'ref #f 'reset)))
(check-exn exn? (lambda () (register-slot! 'atom #f 'reset)))

;;; ---------- 读写（opaque 值，按 index） ----------

(define ed (editor-open "abc" 20 5))
(editor-document-slot-set! ed 0 marks 'm1)
(check-equal? (editor-document-slot-ref ed 0 marks) 'm1)
(check-equal? (document-slot-marks (editor-document-handle ed 0)) 'm1)   ; 命名访问器同源
(check-equal? (editor-view-slot-ref ed 0 marks) 'm1)

;; 句柄版
(editor-document-handle-slot-set! (editor-document-handle ed 0) marks 'm2)
(check-equal? (editor-document-slot-ref ed 0 marks) 'm2)

;; atom
(define sl (editor-view-slot-atom ed 0 marks))
(check-true (box? sl))
(check-equal? (unbox sl) 'm2)

;;; ---------- fork：reset 清值；transform 推进 ----------

(define-values (_chg _ok) (editor-view-insert! ed 0 "X"))   ; 在文首插入 → "Xabc"
(check-equal? (editor-document-string ed 0) "Xabc")
(check-equal? (editor-document-slot-ref ed 0 marks) #f)     ; reset → 默认
(check-equal? (editor-document-slot-ref ed 0 nchanges) 1)   ; transform：+1

;;; ---------- 冻结（文档创建后） ----------
(check-exn exn? (lambda () (register-slot! 'late #f 'reset)))

(displayln "slot-api.rkt: all tests passed")

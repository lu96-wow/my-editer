#lang racket

(require racket/string
         "../core/editor.rkt")

;;; lab-rebuild/input-doc.rkt —— 底部槽位的文档（纯，复用）
;;;
;;; 底部状态栏那条是**共享槽位**：空闲显示 state，输入时切成输入文档，结束切回。
;;; 本文件只负责「文字 → document」，不认识模式、焦点、业务续延。
;;;
;;;   state->document 一行应用状态（整行只读）
;;;   input->document  label 前缀只读 + 其后可写；确认型整行只读
;;;   input-value      从视图字符串剥掉 label，得到用户输入

(provide (struct-out input)
         input->document input-value
         state->document
         input-face state-face)

;; 提示规格：label（只读前缀）+ editable?（可写 / 只确认）。
;; 复用点：谁要输入都只是换 label / editable?，文档构造与表都不变。
(struct input (label editable?) #:transparent)

(define input-face 'input)
(define state-face 'state)

;; 规格 + 当前值 → document。
(define (input->document in [value ""])
  (define label (input-label in))
  (define editable? (input-editable? in))
  ;; 确认型：整行 = label（全只读）；输入型：label 前缀只读。
  (define text (string-append label value))
  (define ro-len (if editable? (string-length label) (string-length text)))
  (define doc (document-open text))
  (unless (zero? (string-length text))
    (document-highlight-fill-batch doc (list (list 0 0 0 (string-length text) input-face))))
  (unless (zero? ro-len)
    (document-readonly-fill-batch doc (list (list 0 0 0 ro-len #t))))
  doc)

;; 从视图字符串反推用户输入（剥掉只读 label）。
(define (input-value in text)
  (define label (input-label in))
  (if (string-prefix? text label) (substring text (string-length label)) text))

;; 状态栏：一行应用状态、整行只读。
(define (state->document text)
  (define doc (document-open text))
  (unless (zero? (string-length text))
    (document-highlight-fill-batch doc (list (list 0 0 0 (string-length text) state-face)))
    (document-readonly-fill-batch doc (list (list 0 0 0 (string-length text) #t))))
  doc)

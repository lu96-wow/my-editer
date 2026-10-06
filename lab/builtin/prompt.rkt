#lang racket

;;; lab-rebuild/builtin/prompt.rkt —— 底部输入框（layer + slot，功能包）。
;;;
;;; prompt 就是一个 layer-spec：
;;;   on-enter  → reload input 视图 + 光标到 label 尾
;;;   on-blur   → 取消（焦点离开即取消）
;;;   tables    → input-edit / confirm
;;;   capture='fallthrough'（文本落 base 编辑 input 文档）
;;;   slot='input'、focus='input-view'
;;;   pop='never'（提交 / 取消显式出栈）
;;;
;;; 提交 / 取消通过 on-commit / on-cancel 返回 effect —— 保持"effect 是唯一写入"。

(require racket/string
         "../kernel/editor-api.rkt"
         "../kernel/binding.rkt"
         "../kernel/effect.rkt"
         "../kernel/layer.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../config/keys.rkt")

(provide register-prompt! e-prompt
         (struct-out prompt) prompt-value)

(struct prompt (label editable? on-commit on-cancel) #:transparent)
;; on-commit : any -> (listof effect)
;; on-cancel : (-> (listof effect))

(define (e-prompt label editable? on-commit [on-cancel (λ () '())])
  (e-input-push 'prompt (prompt label editable? on-commit on-cancel)))

(define (prompt-doc p value)
  (define label (prompt-label p))
  (define text (string-append label value))
  (define doc (document-open text))
  (unless (zero? (string-length label))
    (document-readonly-fill-batch doc (list (list 0 0 0 (string-length label) #t))))
  doc)

(define (prompt-value p text)
  (define label (prompt-label p))
  (if (string-prefix? text label) (substring text (string-length label)) text))

(define prompt-layer
  (make-layer 'prompt
              #:on-enter
              (λ (ctx inst)
                (define p (layer-inst-state inst))
                (define in (session-input-vid (ctx-session ctx)))
                (list (e-reload in (prompt-doc p ""))
                      (e-move in (selections-one (caret (point 0 (string-length (prompt-label p))))))))
              #:on-blur
              (λ (ctx inst)
                (define p (layer-inst-state inst))
                (append ((prompt-on-cancel p)) (list (e-input-pop 'prompt))))
              #:tables
              (λ (ctx inst)
                (define p (layer-inst-state inst))
                (list (if (prompt-editable? p) input-edit-table confirm-table)))
              #:capture 'fallthrough
              #:slot 'input
              #:focus 'input-view
              #:pop 'never))

;;; ================= 命令 =================

(define (current-prompt ctx)
  (define inst (input-find (session-input (ctx-session ctx)) 'prompt))
  (and inst (layer-inst-state inst)))

(define (cmd-prompt-commit ctx ev)
  (define p (current-prompt ctx))
  (cond
    [(not p) '()]
    [else
     (define s (ctx-session ctx))
     (define text (editor-view-string (session-editor s) (session-input-vid s)))
     (append (list (e-input-pop 'prompt)) ((prompt-on-commit p) (prompt-value p text)))]))

(define (cmd-prompt-cancel ctx ev)
  (define p (current-prompt ctx))
  (cond
    [(not p) '()]
    [else (append ((prompt-on-cancel p)) (list (e-input-pop 'prompt)))]))

(define (cmd-prompt-answer ctx ev)
  (define p (current-prompt ctx))
  (cond
    [(not p) '()]
    [else
     (define k (and (key-event? ev) (key-event-key ev)))
     (define yes? (and (char? k) (char=? (char-downcase k) #\y)))
     (append (list (e-input-pop 'prompt)) ((prompt-on-commit p) yes?))]))

;; 演示输入型 prompt：Find file
(define (cmd-find-file ctx ev)
  (list (e-prompt "Find file: " #t
                  (λ (value)
                    (if (positive? (string-length value))
                        (list (e-show value 'replace #t))
                        '())))))

(define (register-prompt! r)
  (reg-add
   (reg-add
    (reg-add
     (reg-add
      (reg-add r (contrib 'layer-spec 'prompt 0 prompt-layer))
      (contrib 'command 'prompt-commit 0 cmd-prompt-commit))
     (contrib 'command 'prompt-cancel 0 cmd-prompt-cancel))
    (contrib 'command 'prompt-answer 0 cmd-prompt-answer))
   (contrib 'command 'find-file 0 cmd-find-file)))

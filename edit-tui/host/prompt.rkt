#lang racket

;;; edit-tui/host/prompt.rkt —— save / quit 输入流程
;;;
;;; 输入栏本身在 editor/input.rkt；这里定义 prompt 种类：
;;;   save-path     无 path 保存
;;;   save-confirm  有 path 保存确认 (y/n)
;;;   quit-confirm  退出前 dirty 确认 (y/n/all/nall)
;;;
;;; 这里只产生 action / State；写文件是 host 解释流程中的副作用。

(require racket/file
         racket/path
         racket/string
         "../core/command/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/resource.rkt"
         "../editor/mode.rkt"
         "../editor/engine/api.rkt"
         "../editor/action.rkt"
         "../editor/layout.rkt"
         "../features/input/api.rkt"
         "close.rkt"
         "filetree-io.rkt"
         "keymap.rkt"
         "../features/find/api.rkt")

(provide editor-save-command
         editor-request-quit
         editor-input-command-table
         editor-input-submit!)

(define (resource-label r)
  (or (resource-path r) (resource-name r)))

(define (dirty-resources state engine)
  (filter (λ (r)
            (resource-dirty? r (engine-doc-version engine (resource-doc-id r))))
          (resources-list (state-resources state))))

(define (focus-resource state)
  (define vid (editor-focus-view-id state))
  (and vid (state-resource-for-view state vid)))

;;; ════════════════ 写文件 ════════════════

;; → (values state ok?)
(define (write-resource! ed state r path)
  (define path* (resource-normalize-path path))
  (define engine (editor-engine ed))
  (define text (engine-doc-text engine (resource-doc-id r)))
  (cond
    [(not text)
     (values (state-with-flash state "save: no text") #f)]
    [else
     (define ok?
       (with-handlers ([exn:fail? (λ (_) #f)])
         (display-to-file text path* #:exists 'truncate)
         #t))
     (cond
       [(not ok?)
        (values (state-with-flash state (format "save failed: ~a" path*)) #f)]
       [else
        (define mode (doc-mode-for path* text))
        (define name
          (let ([n (file-name-from-path path*)])
            (if n (path->string n) path*)))
        (define rs (state-resources state))
        (define rs* (resources-set-path rs (resource-id r) path* name mode))
        (define rs** (resources-set-command-stack rs* (resource-id r)
                                                  (mode-command-stack mode)))
        (define version (engine-doc-version engine (resource-doc-id r)))
        (define rs*** (resources-set-saved-version rs** (resource-id r) version))
        (values (state-with-flash
                 (state-with-resources state rs***)
                 (format "saved: ~a" path*))
                #t)])]))

;;; ════════════════ 打开 prompt ════════════════

(define (open-save-path state context)
  (editor-input-open state 'save-path "Save as: " context))

(define (open-save-confirm state r context)
  (editor-input-open state 'save-confirm
                     (format "Save ~a? (y/n) " (resource-label r))
                     context))

(define (open-quit-confirm state id ids)
  (define r (state-resource-for-doc state id))
  (editor-input-open state 'quit-confirm
                     (format "Save ~a? (y/n/all/nall) " (resource-label r))
                     (list 'quit ids 'ask)))

;;; ════════════════ save 命令 ════════════════

(define (editor-save-command ed state)
  (define r (focus-resource state))
  (cond
    [(not r) (values (state-with-flash state "save: no resource") '())]
    [(resource-path r)
     (values (open-save-confirm state r (list 'save (resource-id r))) '())]
    [else
     (values (open-save-path state (list 'save (resource-id r))) '())]))

;;; ════════════════ quit ════════════════

(define (finish-quit state)
  (values (editor-input-close state) (list (quit-action))))

(define (continue-quit ed state ids mode)
  (cond
    [(or (null? ids) (eq? mode 'none)) (finish-quit state)]
    [(eq? mode 'all)
     (define id (car ids))
     (define r (state-resource-for-doc state id))
     (cond
       [(not r) (continue-quit ed state (cdr ids) 'all)]
       [(resource-path r)
        (define-values (state* ok?) (write-resource! ed state r (resource-path r)))
        (continue-quit ed state* (cdr ids) 'all)]
       [else
        (values (open-save-path state (list 'quit-save (cdr ids) 'all id)) '())])]
    [else (values (open-quit-confirm state (car ids) ids) '())]))

(define (editor-request-quit ed state)
  (define dirty (dirty-resources state (editor-engine ed)))
  (cond
    [(null? dirty) (values state (list (quit-action)))]
    [else
     (define ids (map resource-id dirty))
     (continue-quit ed state ids 'ask)]))

;;; ════════════════ submit ════════════════

(define (valid-confirm? s choices)
  (member (string-downcase (string-trim s)) choices))

(define (continue-after-save ed state context)
  (match context
    [(list 'save rid)
     (values (editor-input-close
              (state-with-flash state
                                       (format "saved: ~a"
                                               (resource-label
                                                (state-resource-for-doc state rid)))))
             '())]
    [(list 'quit-save ids mode rid)
     (continue-quit ed (editor-input-close state) ids mode)]
    [(list 'close-save rid)
     (editor-close-resource! ed (editor-input-close state) rid)]
    [else (values (editor-input-close state) '())]))

(define (submit-save-path ed state context text)
  (cond
    [(string=? (string-trim text) "")
     (values (state-with-flash state "path required") '())]
    [else
     (define rid (case (car context)
                   [(save close-save) (cadr context)]
                   [else (cadddr context)]))
     (define r (state-resource-for-doc state rid))
     (cond
       [(not r) (values (editor-input-close state) '())]
       [else
        (define-values (state* ok?) (write-resource! ed state r text))
        (if ok?
            (continue-after-save ed state* context)
            (values state* '()))])]))

(define (submit-save-confirm ed state context text)
  (define v (string-downcase (string-trim text)))
  (cond
    [(not (member v '("y" "n"))) 
     (values (state-with-flash state "answer: y / n") '())]
    [(string=? v "n") (values (editor-input-close state) '())]
    [else
     (define rid (cadr context))
     (define r (state-resource-for-doc state rid))
     (cond
       [(not r) (values (editor-input-close state) '())]
       [(not (resource-path r))
        (values (open-save-path state (list 'save rid)) '())]
       [else
        (define-values (state* ok?) (write-resource! ed state r (resource-path r)))
        (if ok?
            (values (editor-input-close state*) '())
            (values state* '()))])]))

(define (submit-close-confirm ed state context text)
  (define v (string-downcase (string-trim text)))
  (cond
    [(not (member v '("y" "n")))
     (values (state-with-flash state "answer: y / n") '())]
    [else
     (define rid (cadr context))
     (define r (state-resource-for-doc state rid))
     (cond
       [(not r) (values (editor-input-close state) '())]
       [(string=? v "n") (editor-close-resource! ed (editor-input-close state) rid)]
       [(resource-path r)
        (define-values (state* ok?) (write-resource! ed state r (resource-path r)))
        (if ok?
            (editor-close-resource! ed (editor-input-close state*) rid)
            (values state* '()))]
       [else (values (open-save-path state (list 'close-save rid)) '())])]))

(define (submit-quit-confirm ed state context text)
  (define v (string-downcase (string-trim text)))
  (cond
    [(not (member v '("y" "n" "all" "nall")))
     (values (state-with-flash state "answer: y / n / all / nall") '())]
    [(string=? v "nall") (finish-quit state)]
    [else
     (define ids (cadr context))
     (define id (car ids))
     (define rest (cdr ids))
     (define r (state-resource-for-doc state id))
     (cond
       [(not r) (continue-quit ed state rest (if (string=? v "all") 'all 'ask))]
       [(string=? v "n") (continue-quit ed state rest 'ask)]
       [(string=? v "all")
        (cond
          [(resource-path r)
           (define-values (state* ok?) (write-resource! ed state r (resource-path r)))
           (continue-quit ed state* rest 'all)]
          [else (values (open-save-path state (list 'quit-save rest 'all id)) '())])]
       [else ; y
        (cond
          [(resource-path r)
           (define-values (state* ok?) (write-resource! ed state r (resource-path r)))
           (continue-quit ed state* rest 'ask)]
          [else (values (open-save-path state (list 'quit-save rest 'ask id)) '())])])]))

(define (editor-input-submit! ed state)
  (define kind (editor-input-kind state))
  (define text (or (editor-input-text state) ""))
  (define s (state-input state))
  (define context (and s (input-state-context s)))
  (case kind
    [(save-path) (submit-save-path ed state context text)]
    [(save-confirm) (submit-save-confirm ed state context text)]
    [(quit-confirm) (submit-quit-confirm ed state context text)]
    [(close-confirm) (submit-close-confirm ed state context text)]
    [(filetree-create-file filetree-create-dir)
     (submit-filetree-create! ed state context text)]
    [(filetree-delete-confirm)
     (submit-filetree-delete! ed state context text)]
    [(filetree-rename)
     (submit-filetree-rename! ed state context text)]
    [(filetree-find)
     (submit-filetree-find! ed state context text)]
    [(find)
     (find-submit! ed state context text)]
    [else (values state '())]))

;;; ════════════════ command table ════════════════

(define (cmd f)
  (λ (ed state) (f state)))

(define editor-input-command-table
  (keys
   [(key 'enter) (λ (ed state) (editor-input-submit! ed state))]
   [(key 'escape) (λ (ed state) (editor-input-cancel state))]
   [(key 'g 'ctrl) (λ (ed state) (editor-input-cancel state))]
   [(key 'backspace) (cmd editor-input-backspace)]
   [(key 'delete) (cmd editor-input-delete)]
   [(key 'left) (cmd editor-input-left)]
   [(key 'b 'ctrl) (cmd editor-input-left)]
   [(key 'right) (cmd editor-input-right)]
   [(key 'f 'ctrl) (cmd editor-input-right)]
   [(key 'home) (cmd editor-input-home)]
   [(key 'a 'ctrl) (cmd editor-input-home)]
   [(key 'h 'ctrl) (cmd editor-input-home)]
   [(key 'end) (cmd editor-input-end)]
   [(key 'e 'ctrl) (cmd editor-input-end)]
   [(key 't 'ctrl) (cmd editor-input-end)]))

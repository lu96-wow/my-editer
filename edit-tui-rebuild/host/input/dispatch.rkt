#lang racket

;;; edit-tui-rebuild/host/input/dispatch.rkt —— key token -> command
;;;
;;; 输入层只做四件事：
;;;   1. 根据 focus 选有序 scope；
;;;   2. 把每层 scope 的 plugin 命令表 + host 内置表拼成表列表；
;;;   3. 处理 pending 多键序列，并记住 pending 属于哪组 scope；
;;;   4. 执行命令，或回落到 self-insert / flash。
;;;
;;; input / placement 仍是独占模式：它们直接替换整组表，不叠加 global。

(require racket/string
         "../../core/command/api.rkt"
         "../../editor/host-api.rkt"
         "../../features/input/api.rkt"
         "../../features/placement/api.rkt"
         "../prompt.rkt"
         "../keymap.rkt"
         "scope.rkt")

(provide dispatch-key
         normal-command-tables)

;;; ════════════════ 表 ════════════════

;; host 表也统一成 leaf = ((owner . command) ...)；owner #f = host 命令。
(define (tag-host-command-table table)
  (command-table-from-bindings
   (for/list ([b (in-list (command-table-bindings table))])
     (list (car b) (list (cons #f (cadr b)))))))

(define input-command-table* (tag-host-command-table editor-input-command-table))
(define placement-command-table* (tag-host-command-table placement-command-table))

(define tagged-host-tables
  (for/hash ([scope (in-list '(global editor filetree resources docs))])
    (values scope (tag-host-command-table (host-command-table-for-scope scope)))))

(define (host-table-for-scope scope)
  (hash-ref tagged-host-tables scope
            (λ () (tag-host-command-table command-table-empty))))

(define (normal-command-tables ed state view-scopes)
  (append*
   (for/list ([scope (in-list (command-scopes ed state view-scopes))])
     (list (editor-command-table ed scope)
           (host-table-for-scope scope)))))

;;; ════════════════ 命令执行 ════════════════

(define (need-view state)
  (editor-focus-view-id state))

(define (editor-focused? state)
  (eq? (editor-focus-panel-kind state) 'editor))

(define (flash state text)
  (values (editor-state-with-flash state text) '()))

(define (plugin-ps state owner)
  (and owner (editor-state-plugin-state state owner)))

(define (write-command-ps state owner ps)
  (if owner (editor-state-set-plugin-state state owner ps) state))

(define (run-command ed state vid owner value)
  (define ps (plugin-ps state owner))
  (cond
    ;; 插件 commands 是普通过程：(ed state ps -> values state' ps' actions)
    ;; host 旧命令（input / placement）仍是 (ed state)；它们 owner = #f。
    [(procedure? value)
     (cond
       [owner
        (define-values (state* ps* actions*) (value ed state ps))
        (values (write-command-ps state* owner ps*) actions*)]
       [else (value ed state)])]
    [(guarded-command? value)
     (define-values (state* ps* actions*)
       ((guarded-command-run value) ed state ps))
     (values (write-command-ps state* owner ps*) actions*)]
    [(insert-command? value)
     (cond
       [(not vid) (flash state "insert: no focused editor view")]
       [(not (editor-focused? state)) (flash state "insert: focus is not editor")]
       [else (editor-insert! ed state vid (insert-command-text value))])]
    [(delete-command? value)
     (cond
       [(not vid) (flash state "delete: no focused editor view")]
       [(not (editor-focused? state)) (flash state "delete: focus is not editor")]
       [else (editor-delete! ed state vid (delete-command-kind value))])]
    [(move-command? value)
     (if vid
         (editor-move! ed state vid
                       (move-command-dir value)
                       (move-command-extend? value))
         (flash state "move: no focused editor view"))]
    [(scroll-command? value)
     (if vid
         (editor-scroll! ed state vid (scroll-command-which value))
         (flash state "scroll: no focused editor view"))]
    [(undo-command? value)
     (cond
       [(or (not vid) (not (editor-focused? state)))
        (flash state "undo: focus is not editor")]
       [else (editor-undo! ed state vid)])]
    [(redo-command? value)
     (cond
       [(or (not vid) (not (editor-focused? state)))
        (flash state "redo: focus is not editor")]
       [else (editor-redo! ed state vid)])]
    [(kill-line-command? value)
     (cond
       [(or (not vid) (not (editor-focused? state)))
        (flash state "kill-line: focus is not editor")]
       [else (editor-kill-line! ed state vid)])]
    [(save-command? value)
     (editor-save-command ed state)]
    [(quit-command? value)
     (editor-request-quit ed state)]
    [else
     (values (editor-state-with-flash state (format "not a command: ~a" value))
             '())]))

;;; ════════════════ lookup ════════════════

(define (command-entry-allowed? entry ed state)
  (define owner (car entry))
  (define value (cdr entry))
  (or (not (guarded-command? value))
      ((guarded-command-when-fn value) ed state (plugin-ps state owner))))

(define (lookup-command tables seq ed state)
  (let loop ([ts tables])
    (cond
      [(null? ts) (values 'unbound #f #f)]
      [else
       (define-values (status entries) (command-table-lookup (car ts) seq))
       (case status
         [(command)
          (define hit
            (for/first ([e (in-list entries)]
                        #:when (command-entry-allowed? e ed state))
              e))
          (if hit
              (values 'command (cdr hit) (car hit))
              (loop (cdr ts)))]
         [(prefix) (values 'prefix #f #f)]
         [else (loop (cdr ts))])])))

;;; ════════════════ step ════════════════

(define (dispatch-key ed state tok view-scopes)
  (define state0 (editor-state-clear-flash state))
  (define scopes (command-scopes ed state0 view-scopes))
  (define pending0 (editor-state-pending state0))
  (define pending-scope0 (editor-state-pending-scope state0))
  ;; focus / mode 改变的瞬间，前缀不再属于当前 scope：直接丢弃。
  (define state1
    (if (and (pair? pending0)
             (not (equal? pending-scope0 scopes)))
        (editor-state-clear-pending state0)
        state0))
  (define pending (editor-state-pending state1))
  (define seq (append pending (list tok)))
  (define tables
    (cond
      [(editor-input-active? state1) (list input-command-table*)]
      [(editor-placement-active? state1) (list placement-command-table*)]
      [else (normal-command-tables ed state1 view-scopes)]))
  (let-values ([(status value owner) (lookup-command tables seq ed state1)])
    (case status
      [(command)
       (run-command ed (editor-state-clear-pending state1)
                    (need-view state1) owner value)]
      [(prefix)
       (values (editor-state-with-pending-scope
                (editor-state-with-pending state1 seq) scopes)
               '())]
      [else
       (define s1 (editor-state-clear-pending state1))
       (define text (key-text tok))
       (define vid (need-view s1))
       (cond
         [(and text (null? pending) (editor-input-active? s1))
          (editor-input-self-insert s1 tok)]
         [(and text (null? pending) vid (editor-focused? s1))
          (editor-insert! ed s1 vid text)]
         [(and text (null? pending) (not vid))
          (values (editor-state-with-flash s1 "insert: no focused editor view") '())]
         [(and text (null? pending) (not (editor-focused? s1)))
          (values (editor-state-with-flash s1 "insert: focus is not editor") '())]
         [else
          (values (editor-state-with-flash
                   s1
                   (format "unbound: ~a"
                           (string-join (map key->string seq) " ")))
                  '())])])))

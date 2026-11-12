#lang racket

;;; edit-tui-rebuild/host/filetree-io.rkt —— filetree 创建 / 删除的 host 侧
;;;
;;; 插件只发 create / delete action；这里负责：
;;;   · 打开输入栏（名字 / y-n 确认）
;;;   · 真正写文件系统
;;;   · 关闭被删除路径下已打开的 resource
;;;   · invalidate filetree，让下一次 sync 重扫

(require racket/file
         racket/match
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../features/input/api.rkt"
         "../plugins/filetree/plugin.rkt"
         "close.rkt")

(provide open-filetree-create-prompt!
         open-filetree-delete-prompt!
         submit-filetree-create!
         submit-filetree-delete!)

;;; ════════════════ 刷新 ════════════════

(define (invalidate-filetree state)
  (define ps (editor-state-plugin-state state 'filetree))
  (if (filetree-state? ps)
      (editor-state-set-plugin-state
       state 'filetree
       (struct-copy filetree-state ps [stale? #t]))
      state))

;;; ════════════════ prompt ════════════════

(define (create-prompt-kind kind)
  (case kind
    [(file) 'filetree-create-file]
    [(dir) 'filetree-create-dir]
    [else (error 'open-filetree-create-prompt! "未知 kind：~a" kind)]))

(define (open-filetree-create-prompt! state parent kind)
  (values
   (editor-input-open state
                      (create-prompt-kind kind)
                      (format "New ~a: " (if (eq? kind 'file) "file" "directory"))
                      (list 'filetree-create kind parent))
   '()))

(define (open-filetree-delete-prompt! state path kind)
  (values
   (editor-input-open state
                      'filetree-delete-confirm
                      (format "Delete ~a? (y/n) " (path->string path))
                      (list 'filetree-delete kind path))
   '()))

;;; ════════════════ create ════════════════

(define (valid-new-name? name)
  (and (not (string=? name ""))
       (not (string=? name "."))
       (not (string=? name ".."))
       (not (regexp-match? #rx"[/\\\\]" name))))

(define (create-target! kind target)
  (with-handlers ([exn:fail? (λ (_) #f)])
    (case kind
      [(file) (display-to-file "" target #:exists 'error)]
      [(dir) (make-directory target)]
      [else (error 'create-target! "未知 kind：~a" kind)])
    #t))

(define (submit-filetree-create! ed state context text)
  (match-define (list 'filetree-create kind parent) context)
  (define name (string-trim text))
  (cond
    [(not (valid-new-name? name))
     (values (editor-state-with-flash state "filetree: invalid name") '())]
    [else
     (define target (build-path parent name))
     (cond
       [(create-target! kind target)
        (values (editor-state-with-flash
                 (invalidate-filetree (editor-input-close state))
                 (format "created: ~a" (path->string target)))
                '())]
       [else
        (values (editor-state-with-flash
                 state
                 (format "create failed: ~a" (path->string target)))
                '())])]))

;;; ════════════════ delete ════════════════

;; root 本身或 root 内路径。
(define (path-within? root path)
  (define root* (resource-normalize-path root))
  (define path* (resource-normalize-path path))
  (or (equal? root* path*)
      (let* ([rel (find-relative-path (string->path root*)
                                      (string->path path*))]
             [rel-str (path->string rel)])
        (and (not (absolute-path? rel))
             (not (regexp-match? #rx"^\\.\\.[/\\\\]" rel-str))))))

(define (affected-resource? path kind r)
  (define p (resource-path r))
  (and p
       (case kind
         [(file) (equal? (resource-normalize-path p)
                         (resource-normalize-path path))]
         [(dir) (path-within? path p)]
         [else #f])))

(define (delete-target! path)
  (with-handlers ([exn:fail? (λ (_) #f)])
    (cond
      [(directory-exists? path) (delete-directory/files path)]
      [(file-exists? path) (delete-file path)]
      [else (void)])
    #t))

(define (close-affected-resources! ed state path kind)
  (define affected
    (filter (λ (r) (affected-resource? path kind r))
            (resources-list (editor-state-resources state))))
  (for/fold ([s state] [actions '()])
            ([r (in-list affected)])
    (define-values (s* more)
      (editor-close-resource! ed s (resource-id r)))
    (values s* (append actions more))))

(define (submit-filetree-delete! ed state context text)
  (define answer (string-downcase (string-trim text)))
  (cond
    [(not (member answer '("y" "n")))
     (values (editor-state-with-flash state "answer: y / n") '())]
    [(string=? answer "n")
     (values (editor-input-close state) '())]
    [else
     (match-define (list 'filetree-delete kind path) context)
     (cond
       [(not (delete-target! path))
        (values (editor-state-with-flash
                 state
                 (format "delete failed: ~a" (path->string path)))
                '())]
       [else
        (define state1 (editor-input-close state))
        (define-values (state2 actions)
          (close-affected-resources! ed state1 path kind))
        (values (editor-state-with-flash
                 (invalidate-filetree state2)
                 (format "deleted: ~a" (path->string path)))
                actions)])]))

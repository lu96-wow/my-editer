#lang racket

;;; filetree C-f n / C-f C-f n / C-f d：输入栏 + host IO + 刷新。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "../app/layout.rkt"
         "../plugins/filetree/plugin.rkt"
         "../features/input/api.rkt")

(define root (make-temporary-directory))
(display-to-file "old" (build-path root "old.txt") #:exists 'replace)

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "editor" "abc"))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 2 "*status*" ""))
(void (engine-create-view! engine 2 2))
(void (engine-create-buffer! engine 3 "*filetree*" ""))
(void (engine-create-view! engine 3 3))
(void (engine-create-buffer! engine 5 "*input*" ""))
(void (engine-create-view! engine 5 5))

(define filetree-plugin (make-filetree-plugin #:view 3 #:root root))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list filetree-plugin)))
(define layout (make-editor-layout #:editor-view 1
                                   #:status-views (list 2 5)
                                   #:sidebar-view 3))
(define state
  (make-app-state #:plugin-states (plugins->states (list filetree-plugin))
                  #:workspace-root (resource-normalize-path root)
                  #:area (rect 0 0 60 15)
                  #:layout layout
                  #:layout-config default-layout-config
                  #:view-scopes (plugins->view-scopes (list filetree-plugin))
                  #:input (make-input-state #:panel-id 'status
                                            #:status-view 2
                                            #:input-view 5)))

(define s-sync (run-plugin-syncs ed state))
(define-values (s-side _a-side) (editor-focus! ed s-sync 'left))
(check-equal? (editor-focus-view-id s-side) 3)

(define (key* c) (key-event (key c)))
(define (type-text st text)
  (for/fold ([s st]) ([c (in-string text)])
    (handle-editor-event ed s (key* c))))
(define (submit st)
  (handle-editor-event ed st (key-event (key 'enter))))
(define (backspaces st n)
  (for/fold ([s st]) ([_ (in-range n)])
    (handle-editor-event ed s (key-event (key 'backspace)))))

;; root 行 -> 在 root 下建文件。
(engine-set-view-cursor! engine 3 0 #:column 0)
(define s-cf (handle-editor-event ed s-side (key-event (key 'f 'ctrl))))
(define s-new (handle-editor-event ed s-cf (key-event (key 'n))))
(check-true (editor-input-active? s-new))
(define s-typed (type-text s-new "new.txt"))
(define s-created (submit s-typed))
(check-false (editor-input-active? s-created))
(check-true (file-exists? (build-path root "new.txt")))

;; C-f C-f n：建目录。
(define s-sync2 (run-plugin-syncs ed s-created))
(engine-set-view-cursor! engine 3 0 #:column 0)
(define s-cf1 (handle-editor-event ed s-sync2 (key-event (key 'f 'ctrl))))
(define s-cf2 (handle-editor-event ed s-cf1 (key-event (key 'f 'ctrl))))
(define s-dir-prompt (handle-editor-event ed s-cf2 (key-event (key 'n))))
(check-true (editor-input-active? s-dir-prompt))
(define s-dir-typed (type-text s-dir-prompt "newdir"))
(define s-dir-created (submit s-dir-typed))
(check-true (directory-exists? (build-path root "newdir")))

;; C-f r：改名 old.txt -> renamed.txt；输入栏预填旧名字。
(define s-sync3 (run-plugin-syncs ed s-dir-created))
(define rows (filetree-state-rows (state-plugin-state s-sync3 'filetree)))
(define old-line
  (for/first ([row (in-list rows)] [i (in-naturals)]
              #:when (equal? (car row) (build-path root "old.txt")))
    i))
(check-not-false old-line)
(engine-set-view-cursor! engine 3 old-line #:column 0)
(define s-ren-cf (handle-editor-event ed s-sync3 (key-event (key 'f 'ctrl))))
(define s-ren-prompt (handle-editor-event ed s-ren-cf (key-event (key 'r))))
(check-true (editor-input-active? s-ren-prompt))
(check-equal? (editor-input-text s-ren-prompt) "old.txt")
(define s-ren-cleared (backspaces s-ren-prompt (string-length "old.txt")))
(define s-ren-typed (type-text s-ren-cleared "renamed.txt"))
(define s-renamed (submit s-ren-typed))
(check-false (file-exists? (build-path root "old.txt")))
(check-true (file-exists? (build-path root "renamed.txt")))

;; C-f l：显式刷新，看到外部新建的文件。
(define s-sync4 (run-plugin-syncs ed s-renamed))
(check-true (string-contains? (engine-view-text engine 3) "renamed.txt"))
(display-to-file "external" (build-path root "external.txt") #:exists 'replace)
(define s-ref-cf (handle-editor-event ed s-sync4 (key-event (key 'f 'ctrl))))
(define s-ref (handle-editor-event ed s-ref-cf (key-event (key 'l))))
(define s-sync5 (run-plugin-syncs ed s-ref))
(check-true (string-contains? (engine-view-text engine 3) "external.txt"))

;; C-f d：删除 new.txt。
(define rows2 (filetree-state-rows (state-plugin-state s-sync5 'filetree)))
(define file-line
  (for/first ([row (in-list rows2)] [i (in-naturals)]
              #:when (equal? (car row) (build-path root "new.txt")))
    i))
(check-not-false file-line)
(engine-set-view-cursor! engine 3 file-line #:column 0)
(define s-del-cf (handle-editor-event ed s-sync5 (key-event (key 'f 'ctrl))))
(define s-del-prompt (handle-editor-event ed s-del-cf (key-event (key 'd))))
(check-true (editor-input-active? s-del-prompt))
(define s-yes (type-text s-del-prompt "y"))
(define s-deleted (submit s-yes))
(check-false (file-exists? (build-path root "new.txt")))

(define s-sync6 (run-plugin-syncs ed s-deleted))
(check-false (string-contains? (engine-view-text engine 3) "new.txt"))

(delete-directory/files root)
(displayln "edit-tui/test/filetree-io.rkt: ok")

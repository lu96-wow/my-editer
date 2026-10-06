#lang racket

;;; lab-rebuild/builtin/highlight.rkt —— 属性插件（font-lock 类）包。
;;;
;;; 把「按 document 版本增量算属性（高亮）+ 版本闸门 + 分层写回」接进平台：
;;;   · init        建 feature service（machine / token / 结果缓存）
;;;   · before-render / job-tick → sync（派活）+ poll（写回）
;;;   · document-closed → 清理
;;;   · 写回是 effect e-attr-highlight!（O(1)，不进 history）
;;;
;;; 传输：skeleton 用 sync；换成 place 时只需替换 runner，闸门逻辑不变。
;;; 插件实现按名字从 registry 解析；启用集来自 config/plugins.rkt。

(require "../kernel/editor-api.rkt"
         "../kernel/effect.rkt"
         "../kernel/face.rkt"
         "../kernel/hooks.rkt"
         "../kernel/registry.rkt"
         "../kernel/runtime.rkt"
         "../kernel/session.rkt"
         "../kernel/paths.rkt"
         "../config/plugins.rkt"
         "highlight/api.rkt"
         "highlight/machine.rkt"
         "highlight/registry.rkt")

(provide register-highlight!)

;;; ================= feature service =================

(struct hm (mach tokens next tracked pending results queue) #:mutable)
;; mach    : machine（影子 + 插件状态 + 全量 fills）
;; tokens  : weak-hasheq document -> token
;; next    : token 分配器
;; tracked : hash did -> 最后一次派活的 token
;; pending : hash did -> 本 tick 记下的增量 edits（增量同步用）
;; results : hash (did . token) -> (hash plugin-name -> fills)
;; queue   : box (list (did token name fills))  待 poll

(define (hm-token hm doc)
  (or (hash-ref (hm-tokens hm) doc #f)
      (let ([t (hm-next hm)])
        (set-hm-next! hm (add1 t))
        (hash-set! (hm-tokens hm) doc t)
        t)))

(define (doc-infos ctx)
  (define s (ctx-session ctx))
  (for/list ([did (in-list (editor-document-id-list (session-editor s)))]
             #:when (path-table-path (session-paths s) did))
    (list did (path-table-path (session-paths s) did))))

(define (merge-fills ps all)
  (append* (for/list ([p (in-list ps)])
             (hash-ref all (plugin-name p) '()))))

;; 对每个真实文件：token 变了就推进到新版本，再为「该文档适用的插件集」取 fills 入队。
;; 有上一版本 + 增量 edits → machine-change!（增量）；否则整篇重开。
(define (hm-sync! hm ctx)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (for ([info (in-list (doc-infos ctx))])
    (match-define (list did path) info)
    (define doc (editor-document-handle ed did))
    (define token (hm-token hm doc))
    (define tracked (hash-ref (hm-tracked hm) did #f))
    (unless (eqv? token tracked)
      (define edits (hash-ref (hm-pending hm) did '()))
      (hash-remove! (hm-pending hm) did)
      (cond
        [(and tracked (pair? edits)) (machine-change! (hm-mach hm) did tracked token path edits)]
        [else (machine-open! (hm-mach hm) did token path (document->string doc))])
      (hash-set! (hm-tracked hm) did token)
      (for ([p (in-list (machine-plugins-for (hm-mach hm) did))])
        (define name (plugin-name p))
        (define fl (machine-job (hm-mach hm) did token name path))
        (set-box! (hm-queue hm) (cons (list did token name (or fl '())) (unbox (hm-queue hm))))))))

;; 抽干队列：版本仍当前才收；该 (did,token) 的**适用插件**到齐才写回。
(define (hm-poll! hm ctx)
  (define items (reverse (unbox (hm-queue hm))))
  (set-box! (hm-queue hm) '())
  (for/fold ([effs '()]) ([r (in-list items)])
    (match-define (list did token name fl) r)
    (define ed (session-editor (ctx-session ctx)))
    (define doc (editor-document-handle ed did))
    (cond
      [(not (eqv? token (hm-token hm doc))) effs]     ; 版本闸门
      [else
       (define key (cons did token))
       (define prev (hash-ref (hm-results hm) key (hash)))
       (define now (hash-set prev name fl))
       (hash-set! (hm-results hm) key now)
       (define ps (machine-plugins-for (hm-mach hm) did))
       (if (for/and ([p (in-list ps)]) (hash-has-key? now (plugin-name p)))
           (append effs (list (e-attr-highlight! did (merge-fills ps now) face-compose)))
           effs)])))

(define (hm-forget! hm did)
  (hash-remove! (hm-tracked hm) did)
  (hash-remove! (hm-pending hm) did)
  (hash-remove! (hm-results hm) did)
  (machine-close! (hm-mach hm) did))

;; after-edit：把一次编辑的增记下来（插入文本从新文档读），供下次 sync 增量推进。
(define (note-change-hook ctx args)
  (define hm (service-ref ctx 'highlight))
  (cond
    [(not hm) '()]
    [else
     (match-define (list vid changes) args)
     (define s (ctx-session ctx))
     (define ed (session-editor s))
     (define did (editor-view-document-id ed vid))
     (when (and (pair? changes) (path-table-path (session-paths s) did))
       (hash-set! (hm-pending hm) did
                  (for/list ([ch (in-list changes)])
                    (define b (change-before ch))
                    (define st (range-start b))
                    (define en (range-end b))
                    (list (point-line st) (point-column st)
                          (point-line en) (point-column en)
                          (editor-view-change-text ed vid ch)))))
     '()]))

;;; ================= hooks / init =================

(define (highlight-hook ctx _args)
  (define hm (service-ref ctx 'highlight))
  (cond
    [(not hm) '()]
    [else (hm-sync! hm ctx) (hm-poll! hm ctx)]))

(define (highlight-closed-hook ctx args)
  (define hm (service-ref ctx 'highlight))
  (when hm (hm-forget! hm (car args)))
  '())

(define (highlight-init ctx)
  (when (pair? enabled-attr-plugins)
    (service-put ctx 'highlight
                 (hm (make-machine enabled-attr-plugins)
                     (make-weak-hasheq) 0 (make-hash) (make-hash) (make-hash) (box '())))))

;; effect 处理器（feature 自带）：写回高亮轨。
(define (apply-attr-highlight ctx did fills combine)
  (define doc (editor-document-handle (session-editor (ctx-session ctx)) did))
  (editor-document-handle-set-highlight! doc #f)
  (editor-document-handle-highlight-compose! doc fills combine)
  ctx)

(define (register-highlight! r)
  (for/fold ([r r]) ([c (in-list (list (contrib 'init 'highlight 0 highlight-init)
                                       (contrib 'effect 'attr-highlight 0 apply-attr-highlight)
                                       (contrib 'hook 'highlight 0 (make-hook 'before-render highlight-hook))
                                       (contrib 'hook 'highlight-note 0 (make-hook 'after-edit note-change-hook))
                                       (contrib 'hook 'highlight-closed 0 (make-hook 'document-closed highlight-closed-hook))))])
    (reg-add r c)))

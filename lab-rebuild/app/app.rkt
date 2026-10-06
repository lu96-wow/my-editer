#lang racket

;;; lab-rebuild/app/app.rkt —— 唯一装配点。

(require "../kernel/editor-api.rkt"
         "../kernel/registry.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/frame.rkt"
         "../kernel/focus.rkt"
         "../kernel/layer.rkt"
         "../kernel/table.rkt"
         "../kernel/paths.rkt"
         "../kernel/effect.rkt"
         "../kernel/pipeline.rkt"
         "../config/keys.rkt"
         "../config/packages.rkt"
         "../kernel/panel.rkt"
         "../kernel/render.rkt")

(provide app-init app-open app-render)

(define (build-registry)
  (for/fold ([r (reg-empty)]) ([p (in-list package-catalog)])
    ((cdr p) r)))

(define (app-init root width height #:background? [background? #f])
  (define reg (build-registry))
  (define main-h (max 1 (sub1 height)))
  ;; 底部槽位视图（status / input）
  (define-values (ed1 sdid status-vid)
    (editor-add-document-view (make-blank-editor) (document-open "") width 1 "*status*"))
  (define-values (ed1b _indid input-vid)
    (editor-add-document-view ed1 (document-open "") width 1 "*input*"))
  ;; 主编辑视图
  (define-values (ed2 _did vid)
    (editor-add-document-view ed1b "" width main-h "*scratch*" #:line-numbers? #t))
  ;; 命名表：基础表 + 各功能的 binding 贡献
  (define named
    (for/fold ([h (named-tables)]) ([c (in-list (reg-kind reg 'binding))])
      (define b (contrib-value c))
      (hash-set h (keybinding-table b)
                (keytable-add (hash-ref h (keybinding-table b))
                              (keybinding-key b) (keybinding-spec b)))))
  ;; 命令集：global + 每 did 的表
  (define cs (make-command-set (list (hash-ref named 'edit) (hash-ref named 'global))))
  (define cs2 (command-set-add-doc cs sdid (list (hash-ref named 'readonly))))
  ;; 左栏面板：按 contribution 顺序创建视图 + 登记 per-did 键表
  (define-values (ed3 panels-rev)
    (for/fold ([ed ed2] [ps '()]) ([c (in-list (reg-kind reg 'panel))])
      (define spec (contrib-value c))
      (define-values (ed* vid data) ((panel-spec-make spec) ed width (max 1 (sub1 height))))
      (values ed* (cons (panel spec vid data) ps))))
  (define panels (reverse panels-rev))
  (define cs3 (for/fold ([cs cs2]) ([p (in-list panels)])
                (command-set-add-doc cs
                                     (editor-view-document-id ed3 (panel-vid p))
                                     (panel-spec-keys (panel-pspec p)))))
  (define sess (make-session ed3
                             (frame-new (leaf vid 'edit))
                             (focus-new vid)
                             (input-empty)
                             cs3
                             (make-path-table)
                             width height status-vid input-vid
                             named panels (and (pair? panels) (panel-name (car panels)))))
  (define ctx0 (ctx sess (make-runtime reg (hash) (hash) (hash 'background? background?))))
  ;; 装配后：跑各特性的 init（建 service / 注册需要的运行时状态）
  (for/fold ([c ctx0]) ([e (in-list (reg-kind reg 'init))])
    ((contrib-value e) c)))

;; 打开一个文件并显示（CLI 用）。
(define (app-open ctx path)
  (apply-effects! ctx (list (e-show path 'replace #t))))

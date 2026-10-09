#lang racket

(require "document.rkt"
         "base/point.rkt" "base/selection.rkt" "base/edit.rkt" "base/line.rkt"
         "base/change.rkt")

;;; command.rkt —— 多光标编辑：把一条用户编辑施加到**所有选区**
;;;
;;; 流程（坐标全在「编辑前」空间里算）：
;;;   1. 选区集归一（合并重叠）→ 不重叠、有序
;;;   2. 每个选区 → 一个 span（区间替换）+ 一个「光标落点」（待映射的点）
;;;   3. 守：任一区间含只读格 → **整体拒绝**（ok? = #f）
;;;   4. 从高到低施加（前面的编辑不影响后面的坐标）
;;;   5. 新光标 = 把落点依次映射过所有 span（零宽插入点前进到文本之后）
;;;
;;; 返回 (values document selections changes ok?)。changes = 本次编辑的**变更描述**
;;; （listof change，before 在编辑前坐标、两两不重叠），供外部把**其它视图**的选区
;;; 重基准（见 editor）。change 只存结构、不存文本（要文本用 document-change-text）。

(provide
 command-type command-type-ignore-readonly
 command-backspace command-backspace-ignore-readonly
 command-delete command-delete-ignore-readonly
 command-paste command-paste-ignore-readonly)

;;; ---------- 每个选区 → (span 或 #f) + 光标落点 ----------

;; 打字：选区被 text 取代；落点 = 选区终点（零宽时经映射前进到 text 之后）。
(define (typing-info s text)
  (define-values (a b) (selection-range s))
  (list (span a b text) b))

;; 退格：非空选区删整段；光标退删前一格。落点 = 区间终点（映射后落到区间起点）。
(define (backspace-info doc s)
  (define-values (a b) (selection-range s))
  (cond
    [(not (point=? a b)) (list (span a b "") b)]
    [else
     (define prev (point-left (document-text doc) a))
     (if (point=? prev a)
         (list #f a)                       ; 文首，无操作
         (list (span prev a "") a))]))

;; 前向删除：非空选区删整段；光标删后一格。落点 = 区间终点（映射后落到区间起点）。
(define (delete-info doc s)
  (define-values (a b) (selection-range s))
  (cond
    [(not (point=? a b)) (list (span a b "") b)]
    [else
     (define next (point-right (document-text doc) a))
     (if (point=? next a)
         (list #f b)                       ; 文末，无操作
         (list (span a next "") next))]))

;;; ---------- 统一施加 ----------

(define (span-blocked? doc sp)
  (not (document-editable? doc
                           (point-line (span-start sp)) (point-column (span-start sp))
                           (point-line (span-end sp)) (point-column (span-end sp)))))

(define (span-start<? a b) (point<? (span-start a) (span-start b)))

(define (command-run doc ss compute sticky default guard?)
  (define nss (selections-normalize ss))
  (define infos (for/list ([s (in-list (selections-items nss))]) (compute doc s)))
  (define spans (filter span? (map car infos)))
  (define sources (map cadr infos))
  (cond
    [(and guard? (ormap (lambda (sp) (span-blocked? doc sp)) spans))
     (values doc ss '() #f)]
    [else
     (define doc*
       (for/fold ([d doc]) ([sp (in-list (reverse (sort spans span-start<?)))])
         (document-edit-tracks d (span->edit sp sticky default) (list (span->change sp)))))
     (define changes (filter (lambda (ch) (not (change-empty? ch))) (map span->change spans)))
     (define carets (for/list ([p (in-list sources)]) (caret (changes-map-point changes p))))
     (values doc*
             (selections-dedupe (selections carets (selections-primary-index nss)))
             changes
             #t)]))

;;; ---------- 用户命令（守 / -ignore-readonly） ----------

(define (command-type doc ss text [sticky 'none] [default #f])
  (command-run doc ss (lambda (_doc s) (typing-info s text)) sticky default #t))
(define (command-type-ignore-readonly doc ss text [sticky 'none] [default #f])
  (command-run doc ss (lambda (_doc s) (typing-info s text)) sticky default #f))

(define (command-backspace doc ss) (command-run doc ss backspace-info 'none #f #t))
(define (command-backspace-ignore-readonly doc ss) (command-run doc ss backspace-info 'none #f #f))

(define (command-delete doc ss) (command-run doc ss delete-info 'none #f #t))
(define (command-delete-ignore-readonly doc ss) (command-run doc ss delete-info 'none #f #f))

;;; ---------- 粘贴：纯文本 ----------
;;; 剪贴板只有文本；粘贴 = 用文本替换每个选区，与 command-type 同构（多光标、成对守卫）。

(define (command-paste doc ss text) (command-type doc ss text))
(define (command-paste-ignore-readonly doc ss text) (command-type-ignore-readonly doc ss text))

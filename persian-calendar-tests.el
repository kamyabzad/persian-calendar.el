;;; persian-calendar-tests.el --- Tests for persian-calendar -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q -batch -L . -l persian-calendar.el \
;;     -l persian-calendar-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'persian-calendar)
(require 'diary-lib)

(defmacro persian-calendar-tests--with-calendar (&rest body)
  "Set up a fresh calendar buffer, run BODY inside it, then clean up."
  `(save-window-excursion
     (unwind-protect
         (progn
           (calendar-basic-setup nil t)
           (set-window-buffer (selected-window) (get-buffer calendar-buffer))
           (with-current-buffer calendar-buffer
             ,@body))
       (when (get-buffer calendar-buffer)
         (kill-buffer calendar-buffer)))))

(ert-deftest persian-calendar-test-conversion-anchors ()
  (should (equal (persian-calendar--to-gregorian '(1 1 1405))
                 '(3 21 2026)))
  (should (equal (persian-calendar--from-gregorian '(9 28 2026))
                 '(7 6 1405)))
  (should (= (calendar-persian-last-day-of-month 12 1399) 30))
  (should (equal (persian-calendar--from-gregorian
                  (persian-calendar--to-gregorian '(12 30 1399)))
                 '(12 30 1399))))

(ert-deftest persian-calendar-test-enable-displays-persian-window ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (let ((ptoday (persian-calendar--from-gregorian
                  (calendar-current-date))))
     (should (= displayed-month (calendar-extract-month ptoday)))
     (should (= displayed-year (calendar-extract-year ptoday))))
   (should (equal (calendar-cursor-to-date) (calendar-current-date)))))

(ert-deftest persian-calendar-test-roundtrip-all-visible-dates ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (let* ((range (calendar-get-date-range t))
          (day (calendar-absolute-from-gregorian (car range)))
          (last (calendar-absolute-from-gregorian (cdr range))))
     (should (> last day))
     (while (<= day last)
       (let ((date (calendar-gregorian-from-absolute day)))
         (should (calendar-date-is-visible-p date))
         (calendar-cursor-to-visible-date date)
         (should (equal (calendar-cursor-to-date) date)))
       (setq day (1+ day))))))

(ert-deftest persian-calendar-test-roundtrip-after-scroll ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-scroll-left 1)
   (let* ((range (calendar-get-date-range t))
          (day (calendar-absolute-from-gregorian (car range)))
          (last (calendar-absolute-from-gregorian (cdr range))))
     (while (<= day last)
       (let ((date (calendar-gregorian-from-absolute day)))
         (calendar-cursor-to-visible-date date)
         (should (equal (calendar-cursor-to-date) date)))
       (setq day (1+ day))))))

(ert-deftest persian-calendar-test-toggle-preserves-cursor ()
  (persian-calendar-tests--with-calendar
   (let ((start (calendar-cursor-to-nearest-date)))
     (persian-calendar-mode 1)
     (should (equal (calendar-cursor-to-date) start))
     (persian-calendar-mode -1)
     (should (equal (calendar-cursor-to-date) start))
     (should (= displayed-month (calendar-extract-month start)))
     (should (= displayed-year (calendar-extract-year start)))
     (let* ((range (calendar-get-date-range t))
            (day (calendar-absolute-from-gregorian (car range)))
            (last (calendar-absolute-from-gregorian (cdr range))))
       (while (<= day last)
         (let ((date (calendar-gregorian-from-absolute day)))
           (calendar-cursor-to-visible-date date)
           (should (equal (calendar-cursor-to-date) date)))
         (setq day (1+ day)))))))

(ert-deftest persian-calendar-test-visibility-bounds ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (let* ((range (calendar-get-date-range t))
          (first (calendar-absolute-from-gregorian (car range)))
          (last (calendar-absolute-from-gregorian (cdr range))))
     (should (calendar-date-is-visible-p
              (calendar-gregorian-from-absolute first)))
     (should (calendar-date-is-visible-p
              (calendar-gregorian-from-absolute last)))
     (should-not (calendar-date-is-visible-p
                  (calendar-gregorian-from-absolute (1- first))))
     (should-not (calendar-date-is-visible-p
                  (calendar-gregorian-from-absolute (1+ last)))))))

(ert-deftest persian-calendar-test-mark-visible-date-guard ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (let* ((range (calendar-get-date-range t))
          (inside (car range))
          (outside (calendar-gregorian-from-absolute
                    (- (calendar-absolute-from-gregorian (car range)) 10))))
     (calendar-mark-visible-date inside)
     (calendar-cursor-to-visible-date inside)
     (should (overlays-in (1- (point)) (1+ (point))))
     (should-not (calendar-mark-visible-date outside)))))

(ert-deftest persian-calendar-test-forward-month-clamps-day ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-goto-date (persian-calendar--to-gregorian '(6 31 1404)))
   (calendar-forward-month 1)
   (should (equal (persian-calendar--from-gregorian
                   (calendar-cursor-to-date))
                  '(7 30 1404)))))

(ert-deftest persian-calendar-test-month-boundaries ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-goto-date (persian-calendar--to-gregorian '(7 15 1405)))
   (calendar-beginning-of-month 1)
   (should (equal (persian-calendar--from-gregorian
                   (calendar-cursor-to-date))
                  '(7 1 1405)))
   (calendar-end-of-month 1)
   (should (equal (persian-calendar--from-gregorian
                   (calendar-cursor-to-date))
                  '(7 30 1405)))))

(ert-deftest persian-calendar-test-year-boundaries ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-goto-date (persian-calendar--to-gregorian '(7 15 1405)))
   (calendar-beginning-of-year 1)
   (should (equal (persian-calendar--from-gregorian
                   (calendar-cursor-to-date))
                  '(1 1 1405)))
   (calendar-goto-date (persian-calendar--to-gregorian '(7 15 1405)))
   (calendar-end-of-year 1)
   (should (equal (persian-calendar--from-gregorian
                   (calendar-cursor-to-date))
                  '(12 29 1405)))))

(ert-deftest persian-calendar-test-goto-far-date ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-goto-date '(1 15 2030))
   (should (equal (calendar-cursor-to-date) '(1 15 2030)))
   (calendar-goto-today)
   (should (equal (calendar-cursor-to-date) (calendar-current-date)))))

(ert-deftest persian-calendar-test-persian-goto-date ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-persian-goto-date '(1 1 1410) t)
   (should (equal (persian-calendar--from-gregorian
                   (calendar-cursor-to-date))
                  '(1 1 1410)))))

(ert-deftest persian-calendar-test-mark-date-pattern ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (let* ((range (calendar-get-date-range t))
          (target (calendar-gregorian-from-absolute
                   (+ 5 (calendar-absolute-from-gregorian (car range))))))
     (calendar-mark-date-pattern (calendar-extract-month target)
                                 (calendar-extract-day target)
                                 (calendar-extract-year target))
     (calendar-cursor-to-visible-date target)
     (should (overlays-in (1- (point)) (1+ (point)))))))

(ert-deftest persian-calendar-test-mark-days-named ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-mark-days-named 5)
   (let* ((range (calendar-get-date-range t))
          (day (calendar-absolute-from-gregorian (car range)))
          (last (calendar-absolute-from-gregorian (cdr range)))
          (found 0))
     (while (<= day last)
       (when (= (mod day 7) 5)
         (calendar-cursor-to-visible-date
          (calendar-gregorian-from-absolute day))
         (when (overlays-in (1- (point)) (1+ (point)))
           (setq found (1+ found))))
       (setq day (1+ day)))
     (should (>= found 12)))))

(ert-deftest persian-calendar-test-gregorian-untouched-when-off ()
  (persian-calendar-tests--with-calendar
   (let* ((today (calendar-current-date))
          (month (calendar-extract-month today))
          (day (calendar-extract-day today))
          (year (calendar-extract-year today)))
     (should (equal (calendar-cursor-to-date) today))
     (should (= displayed-month month))
     (calendar-forward-month 1)
     (calendar-increment-month month year 1)
     (should (equal (calendar-cursor-to-date)
                    (list month
                          (min day (calendar-last-day-of-month month year))
                          year)))
     (calendar-scroll-left 1)
     (calendar-goto-today)
     (should (equal (calendar-cursor-to-date) today)))))

(ert-deftest persian-calendar-test-official-1404 ()
  (should (equal (persian-calendar--to-gregorian '(1 1 1404))
                 '(3 21 2025)))
  (should (= (calendar-persian-last-day-of-month 12 1403) 30))
  (should (calendar-persian-leap-year-p 1403))
  (should-not (calendar-persian-leap-year-p 1404))
  (should (equal (persian-calendar--from-gregorian '(3 20 2025))
                 '(12 30 1403))))

(ert-deftest persian-calendar-test-official-vs-birashk-divergence ()
  (let (divergent)
    (dolist (y (number-sequence 1300 1500))
      (let ((official (persian-calendar--official-leap-year-p y))
            (birashk (let ((persian-calendar-official-calendar nil))
                       (calendar-persian-leap-year-p y))))
        (unless (eq official birashk)
          (push y divergent))))
    (should (equal (nreverse divergent)
                   '(1403 1404 1436 1437 1469 1470)))))

(ert-deftest persian-calendar-test-official-roundtrip ()
  (let ((day (persian-calendar--official-to-absolute '(1 1 1390))))
    (dotimes (i 14600)
      (let ((p (persian-calendar--official-from-absolute (+ day i))))
        (should (= (+ day i)
                   (persian-calendar--official-to-absolute p)))))))

(ert-deftest persian-calendar-test-official-disabled-restores-birashk ()
  (let ((persian-calendar-official-calendar nil))
    (should (equal (persian-calendar--to-gregorian '(1 1 1404))
                   '(3 20 2025)))
    (should (calendar-persian-leap-year-p 1404))))

(ert-deftest persian-calendar-test-official-grid-1404 ()
  (persian-calendar-tests--with-calendar
   (persian-calendar-mode 1)
   (calendar-persian-goto-date '(1 1 1404) t)
   (should (equal (calendar-cursor-to-date) '(3 21 2025)))
   (calendar-persian-goto-date '(12 30 1403) t)
   (should (equal (calendar-cursor-to-date) '(3 20 2025)))))

(ert-deftest persian-calendar-test-custom-week-start-day ()
  (let ((persian-calendar-week-start-day 0))
    (persian-calendar-tests--with-calendar
     (persian-calendar-mode 1)
     (should (= calendar-week-start-day 0))
     (let* ((range (calendar-get-date-range t))
            (day (calendar-absolute-from-gregorian (car range)))
            (last (calendar-absolute-from-gregorian (cdr range))))
       (while (<= day last)
         (let ((date (calendar-gregorian-from-absolute day)))
           (calendar-cursor-to-visible-date date)
           (should (equal (calendar-cursor-to-date) date)))
         (setq day (1+ day))))
     (persian-calendar-mode -1)
     (should-not (local-variable-p 'calendar-week-start-day)))))

(ert-deftest persian-calendar-test-auto-enable ()
  (let ((persian-calendar-auto-enable t))
    (persian-calendar-tests--with-calendar
     (should persian-calendar-mode)
     (let ((ptoday (persian-calendar--from-gregorian
                    (calendar-current-date))))
       (should (= displayed-month (calendar-extract-month ptoday)))
       (should (= displayed-year (calendar-extract-year ptoday)))))))

(provide 'persian-calendar-tests)

;;; persian-calendar-tests.el ends here

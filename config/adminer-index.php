<?php
// Adminer login-page preset for the coding-platform DB.
//
// Overrides the standard entrypoint so the login form lands on the
// coding_platform database + app schema by default. This file is mounted
// at /var/www/html/index.php inside the adminer:*-standalone image.
function adminer_object() {
    class CustomAdminer extends Adminer {
        function loginForm() {
            if (!isset($_GET['db'])) {
                $_GET['db'] = 'coding_platform';
            }
            if (!isset($_GET['ns'])) {
                $_GET['ns'] = 'app';
            }
            return parent::loginForm();
        }
    }
    return new CustomAdminer;
}
include './adminer.php';
